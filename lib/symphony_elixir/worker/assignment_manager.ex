defmodule SymphonyElixir.Worker.AssignmentManager do
  @moduledoc """
  Owns the Panel's single ephemeral worker assignment.

  Every assignment starts from a fresh tracker candidate read and a second issue read. Nothing in
  PostgreSQL is treated as queued work; runs and events are audit history only.
  """

  use GenServer

  alias SymphonyElixir.{
    Config,
    EnvironmentFailureCircuit,
    Orchestrator,
    PersistenceProvider,
    PromptBuilder,
    RunLifecycle,
    Tracker,
    WorkerResult,
    WorkflowStore
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{DispatchPolicy, Events}

  @terminal_events ["task.completed", "task.failed", "task.cancelled"]
  @initial_poll_seconds 5
  @backoff_poll_seconds 30
  @max_poll_seconds 60

  @type assignment :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec claim(String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, assignment() | {:empty, pos_integer()}} | {:error, term()} | {:error, term(), pos_integer()}
  def claim(worker_id, session_id, attrs, server \\ __MODULE__) do
    case claim_with_evidence(worker_id, session_id, attrs, server) do
      {:ok, result, _evidence} -> {:ok, result}
      {:error, reason, seconds} -> {:error, reason, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec claim_with_evidence(String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, assignment() | {:empty, pos_integer()}, map()} | {:error, term()} | {:error, term(), pos_integer()}
  def claim_with_evidence(worker_id, session_id, attrs, server \\ __MODULE__) do
    if process_alive?(server),
      do: GenServer.call(server, {:claim, worker_id, session_id, attrs}, :infinity),
      else: {:ok, {:empty, @initial_poll_seconds}, admission_evidence(:worker_dispatch_disabled)}
  end

  @spec heartbeat(String.t(), String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def heartbeat(worker_id, session_id, attrs, server \\ __MODULE__),
    do: if(process_alive?(server), do: GenServer.call(server, {:heartbeat, worker_id, session_id, attrs}), else: inactive_heartbeat(worker_id, session_id))

  @spec record_event(String.t(), String.t(), String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def record_event(worker_id, session_id, assignment_id, event_type, payload, server \\ __MODULE__),
    do: if(process_alive?(server), do: GenServer.call(server, {:event, worker_id, session_id, assignment_id, event_type, payload}), else: {:error, :lease_not_active})

  @spec current_assignment(GenServer.server()) :: assignment() | nil
  def current_assignment(server \\ __MODULE__) do
    if process_alive?(server), do: GenServer.call(server, :current_assignment), else: nil
  end

  @spec cancel_current(String.t(), GenServer.server()) :: :ok
  def cancel_current(reason, server \\ __MODULE__) do
    if process_alive?(server), do: GenServer.call(server, {:cancel_current, reason}), else: :ok
  end

  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.cast(server, :reconcile)

  @impl true
  def init(opts) do
    state = %{
      assignment: nil,
      tracker: Keyword.get(opts, :tracker, Tracker),
      persistence: Keyword.get(opts, :persistence, PersistenceProvider.module()),
      workflows: Keyword.get(opts, :workflows, WorkflowStore),
      orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      failure_circuit: Keyword.get(opts, :failure_circuit, EnvironmentFailureCircuit),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 10_000),
      empty_claim_streak: 0,
      tracker_error_streak: 0
    }

    schedule_reconciliation(state)
    {:ok, state}
  end

  @impl true
  def handle_cast(:reconcile, state), do: {:noreply, reconcile_zombies(state)}

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile_zombies(state)
    schedule_reconciliation(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:current_assignment, _from, state), do: {:reply, state.assignment, state}

  def handle_call({:cancel_current, _reason}, _from, %{assignment: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:cancel_current, reason}, _from, state) do
    assignment = state.assignment

    _ = persist_event(state.persistence, assignment, "task.cancelled", %{"reason" => reason}, nil)
    _ = transition_run(state.persistence, assignment.run_id, "task.cancelled", nil)
    notify_worker_terminal(state, assignment, :cancelled)
    {:reply, :ok, %{state | assignment: nil}}
  end

  def handle_call({:claim, worker_id, session_id, attrs}, _from, state) do
    state = expire_assignment(state)

    result =
      with {:ok, worker, session} <- state.persistence.fresh_worker_session(worker_id, session_id, now: state.now.()),
           true <- available_slots(attrs) > 0,
           :allow <- EnvironmentFailureCircuit.check(state.failure_circuit),
           nil <- state.assignment do
        case claim_from_workflows(state, worker, session) do
          {:ok, nil} ->
            {:ok, nil, admission_evidence(:no_eligible_candidate)}

          {:ok, assignment} ->
            Orchestrator.worker_task_started(assignment, state.orchestrator)
            {:ok, assignment, admission_evidence(:assigned)}

          error ->
            error
        end
      else
        {:block, circuit} ->
          {:bypass, @max_poll_seconds, environment_failure_circuit_evidence(circuit)}

        %{} ->
          {:bypass, @initial_poll_seconds, admission_evidence(:active_assignment)}

        false ->
          {:bypass, @initial_poll_seconds, admission_evidence(:no_available_slots)}

        {:error, reason} when reason in [:worker_session_not_found, :worker_session_offline, :worker_session_stale] ->
          {:bypass, @initial_poll_seconds, admission_evidence(reason)}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:ok, %{} = assignment, evidence} ->
        state = %{state | assignment: assignment, empty_claim_streak: 0, tracker_error_streak: 0}
        {:reply, {:ok, assignment, evidence}, state}

      {:ok, nil, evidence} ->
        streak = state.empty_claim_streak + 1
        seconds = empty_poll_seconds(streak)
        {:reply, {:ok, {:empty, seconds}, evidence}, %{state | empty_claim_streak: streak, tracker_error_streak: 0}}

      {:bypass, seconds, evidence} ->
        {:reply, {:ok, {:empty, seconds}, evidence}, state}

      {:error, reason} = error ->
        if tracker_backoff_error?(reason) do
          streak = state.tracker_error_streak + 1
          seconds = failure_poll_seconds(streak)
          {:reply, {:error, reason, seconds}, %{state | tracker_error_streak: streak}}
        else
          {:reply, error, state}
        end
    end
  end

  def handle_call({:heartbeat, worker_id, session_id, attrs}, _from, state) do
    state = expire_assignment(state)

    case state.persistence.heartbeat_worker(worker_id, session_id) do
      {:ok, base} ->
        active_ids = map_get(attrs, "active_leases", :active_leases) || []
        {assignment, renewals} = renew_assignment(state.assignment, worker_id, session_id, active_ids, state)

        reply = {:ok, Map.merge(base, %{lease_renewals: renewals, commands: []})}
        {:reply, reply, %{state | assignment: assignment}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:event, worker_id, session_id, assignment_id, event_type, payload}, _from, state) do
    state = expire_assignment(state)

    with {:ok, assignment} <- matching_assignment(state.assignment, worker_id, session_id, assignment_id),
         :ok <- validate_correlation(payload, assignment.correlation),
         {:ok, summary} <- WorkerResult.validate_event(event_type, payload),
         {:ok, event} <- persist_event(state.persistence, assignment, event_type, payload, summary),
         :ok <- transition_run(state.persistence, assignment.run_id, event_type, summary) do
      record_environment_failure_circuit(state, assignment, event_type, summary)
      notify_orchestrator(state, assignment, event_type, event_payload_with_time(payload, event), summary)
      assignment = if event_type in @terminal_events, do: nil, else: assignment
      {:reply, {:ok, event}, %{state | assignment: assignment}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp claim_from_workflows(state, worker, session) do
    Enum.reduce_while(state.workflows.list_enabled(), {:ok, nil}, fn workflow, _acc ->
      result = Config.with_workflow_context(workflow, fn -> claim_from_workflow(state, worker, session, workflow) end)
      if match?({:ok, nil}, result), do: {:cont, result}, else: {:halt, result}
    end)
  end

  defp empty_poll_seconds(1), do: @initial_poll_seconds
  defp empty_poll_seconds(streak) when streak in 2..5, do: @backoff_poll_seconds
  defp empty_poll_seconds(_streak), do: @max_poll_seconds

  defp failure_poll_seconds(1), do: @backoff_poll_seconds
  defp failure_poll_seconds(_streak), do: @max_poll_seconds

  defp tracker_backoff_error?({:linear_api_status, status, _body}) when status == 429 or status in 500..599, do: true
  defp tracker_backoff_error?({:linear_api_request, _reason}), do: true
  defp tracker_backoff_error?(_reason), do: false

  defp claim_from_workflow(state, worker, session, workflow) do
    with {:ok, candidates} <- state.tracker.fetch_candidate_issues(),
         %Issue{} = candidate <- select_candidate(candidates, state.persistence),
         {:ok, %Issue{} = issue} <- revalidate(candidate, state.tracker),
         {:ok, assignment} <- create_assignment(state, worker, session, workflow, issue) do
      {:ok, assignment}
    else
      nil -> {:ok, nil}
      {:skip, _reason} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_candidate(candidates, persistence) do
    candidates
    |> DispatchPolicy.sort_issues_for_dispatch()
    |> Enum.find(&(eligible_issue?(&1) and dispatchable_from_history?(&1, persistence)))
  end

  defp dispatchable_from_history?(%Issue{state: state}, _persistence)
       when state not in ["In Progress", "in progress"],
       do: true

  defp dispatchable_from_history?(%Issue{} = issue, persistence) do
    case persistence.list_runs_for_issue(issue.identifier, limit: 1) do
      [%{status: status} | _] -> status in ["succeeded", "failed", "cancelled"]
      [] -> false
      {:error, _reason} -> false
    end
  end

  defp eligible_issue?(%Issue{} = issue) do
    normalized = SymphonyElixir.StateName.normalize(issue.state)
    active = Config.settings!().tracker.active_states |> DispatchPolicy.normalized_state_set()
    MapSet.member?(active, normalized) and issue.blocked_by == [] and !Config.human_review_state?(issue.state)
  end

  defp revalidate(%Issue{id: issue_id}, tracker) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> if eligible_issue?(issue), do: {:ok, issue}, else: {:skip, :stale}
      {:ok, []} -> {:skip, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_assignment(state, worker, session, workflow, issue) do
    now = state.now.()
    assignment_id = Ecto.UUID.generate()
    expires_at = DateTime.add(now, state.persistence.worker_lease_duration_seconds(), :second)
    project_id = workflow.project_id
    profile = Config.workflow_profile_for_state(issue.state)

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: profile,
        profile_policy: Config.workflow_profile(profile),
        allowed_updates: Config.workflow_allowed_updates(profile)
      )

    with {:ok, issue_record} <-
           state.persistence.upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id)),
         {:ok, run} <- create_run(state.persistence, issue, workflow, issue_record.id, project_id, now),
         :ok <- move_to_in_progress(state.tracker, issue),
         issue <- %{issue | state: "In Progress"},
         assignment <-
           build_assignment(assignment_id, issue, run, worker, session, workflow,
             prompt: prompt,
             profile: profile,
             expires_at: expires_at
           ),
         {:ok, _event} <- state.persistence.record_event(assignment_event(assignment, "task.accepted", %{})) do
      {:ok, assignment}
    else
      {:error, reason} = error ->
        close_failed_run(state.persistence, issue.identifier, reason)
        error
    end
  end

  defp create_run(persistence, issue, workflow, issue_id, project_id, started_at) do
    attrs =
      issue
      |> Events.run_attrs(workflow, "worker", nil)
      |> Map.merge(%{issue_id: issue_id, project_id: project_id, status: "running", started_at: started_at})

    persistence.create_run(attrs)
  end

  defp build_assignment(id, issue, run, worker, session, workflow, opts) do
    payload = Events.worker_assignment_payload(issue, run, workflow, opts[:prompt], opts[:profile]).payload

    correlation = %{
      "project_id" => run.project_id,
      "run_id" => run.id,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "run_attempt" => run.attempt,
      "task_id" => id,
      "lease_id" => id,
      "lease_attempt" => 1,
      "worker_id" => worker.id,
      "worker_session_id" => session.id,
      "assignment_id" => id
    }

    %{
      id: id,
      task_id: id,
      lease_id: id,
      issue: issue,
      issue_identifier: issue.identifier,
      project_id: run.project_id,
      run_id: run.id,
      worker_id: worker.id,
      worker_name: Map.get(worker, :name),
      session_id: session.id,
      started_at: Map.get(run, :started_at),
      expires_at: opts[:expires_at],
      payload: payload,
      correlation: correlation
    }
  end

  defp move_to_in_progress(_tracker, %Issue{state: state}) when state in ["In Progress", "in progress"], do: :ok
  defp move_to_in_progress(tracker, %Issue{id: issue_id}), do: tracker.update_issue_state(issue_id, "In Progress")

  defp renew_assignment(nil, _worker_id, _session_id, _active_ids, _state), do: {nil, []}

  defp renew_assignment(assignment, worker_id, session_id, active_ids, state) do
    owned? = assignment.worker_id == worker_id and assignment.session_id == session_id

    if owned? and assignment.lease_id in active_ids do
      expires_at = DateTime.add(state.now.(), state.persistence.worker_lease_duration_seconds(), :second)
      renewal = %{lease_id: assignment.lease_id, lease_expires_at: expires_at}
      {%{assignment | expires_at: expires_at}, [renewal]}
    else
      {assignment, []}
    end
  end

  defp expire_assignment(%{assignment: nil} = state), do: state

  defp expire_assignment(state) do
    if DateTime.compare(state.assignment.expires_at, state.now.()) == :lt do
      assignment = state.assignment

      _ = transition_run(state.persistence, assignment.run_id, "task.failed", nil)
      _ = persist_event(state.persistence, assignment, "task.failed", %{"reason" => "assignment_expired"}, nil)
      notify_worker_terminal(state, assignment, {:failed, "assignment_expired"})
      %{state | assignment: nil}
    else
      state
    end
  end

  defp matching_assignment(nil, _worker_id, _session_id, _id), do: {:error, :lease_not_active}

  defp matching_assignment(assignment, worker_id, session_id, id) do
    if assignment.id == id and assignment.worker_id == worker_id and assignment.session_id == session_id,
      do: {:ok, assignment},
      else: {:error, :lease_not_active}
  end

  defp persist_event(persistence, assignment, event_type, payload, summary) do
    event_payload = payload |> stringify_keys() |> Map.put("correlation", assignment.correlation) |> maybe_put_summary(summary)
    persistence.record_event(assignment_event(assignment, event_type, event_payload))
  end

  defp assignment_event(assignment, event_type, payload) do
    %{
      project_id: assignment.project_id,
      run_id: assignment.run_id,
      issue_identifier: assignment.issue_identifier,
      event_type: event_type,
      payload: Map.put_new(payload, "correlation", assignment.correlation)
    }
  end

  defp transition_run(persistence, run_id, event_type, summary) do
    attrs = RunLifecycle.run_event_attrs(event_type, DateTime.utc_now())
    attrs = if summary, do: Map.put(attrs, :execution_summary, summary), else: attrs

    case {attrs, persistence.get_run(run_id)} do
      {%{}, _run} when map_size(attrs) == 0 ->
        :ok

      {_attrs, nil} ->
        {:error, :run_not_found}

      {attrs, run} ->
        case persistence.update_run(run, attrs) do
          {:ok, _run} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp close_failed_run(persistence, identifier, reason) do
    case persistence.list_runs_for_issue(identifier, limit: 1) do
      [run | _] -> persistence.finish_run(run.id, "failed", inspect(reason))
      _other -> :ok
    end
  end

  defp reconcile_zombies(state) do
    state.persistence.expire_stale_worker_sessions(now: state.now.())

    Enum.each(state.workflows.list_enabled(), fn workflow ->
      Config.with_workflow_context(workflow, fn -> reconcile_workflow_zombies(state) end)
    end)

    expire_assignment(state)
  end

  defp reconcile_workflow_zombies(state) do
    case state.tracker.fetch_issues_by_states(["In Progress"]) do
      {:ok, issues} -> Enum.each(issues, &reconcile_zombie(state, &1))
      {:error, _reason} -> :ok
    end
  end

  defp reconcile_zombie(%{assignment: %{issue: %{id: issue_id}}}, %Issue{id: issue_id}), do: :ok

  defp reconcile_zombie(state, %Issue{} = issue) do
    case state.persistence.list_runs_for_issue(issue.identifier, limit: 1) do
      [run | _] -> maybe_requeue_zombie(state, issue, run)
      _none -> :ok
    end
  end

  defp maybe_requeue_zombie(state, issue, %{status: "running", started_at: %DateTime{} = started_at} = run) do
    cutoff = DateTime.add(state.now.(), -state.persistence.worker_lease_duration_seconds(), :second)

    if DateTime.compare(started_at, cutoff) == :lt do
      with :ok <- state.tracker.update_issue_state(issue.id, "Ready"),
           {:ok, _run} <- state.persistence.finish_run(run.id, "failed", "worker_assignment_lost") do
        state.persistence.record_event(%{
          project_id: run.project_id,
          run_id: run.id,
          issue_identifier: issue.identifier,
          event_type: "task.failed",
          payload: %{"reason" => "panel_restart_or_worker_loss"}
        })
      end
    end
  end

  defp maybe_requeue_zombie(_state, _issue, _run), do: :ok

  defp schedule_reconciliation(state) do
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
  end

  defp available_slots(attrs), do: map_get(attrs, "available_slots", :available_slots) || 0

  defp admission_evidence(reason) do
    %{capacity: if(reason == :assigned, do: 1, else: 0), reason: reason}
  end

  defp environment_failure_circuit_evidence(circuit) do
    :environment_failure_circuit_open
    |> admission_evidence()
    |> Map.put(:failure_fingerprint, circuit.triggering_fingerprint)
  end

  defp record_environment_failure_circuit(state, assignment, "task.completed", _summary) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(state, assignment, "task.cancelled", _summary) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(state, assignment, "task.failed", summary) do
    circuit =
      EnvironmentFailureCircuit.record_failure(
        assignment.issue_identifier,
        worker_failure_reason(summary),
        %{issue_id: assignment.issue.id, run_id: assignment.run_id},
        state.failure_circuit
      )

    if circuit.alert do
      state.persistence.record_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, assignment.project_id))
    end
  end

  defp record_environment_failure_circuit(_state, _assignment, _event_type, _summary), do: :ok

  defp worker_failure_reason(summary) do
    Map.get(summary, "detail") || failed_gate_detail(summary) || Map.fetch!(summary, "reason")
  end

  defp failed_gate_detail(%{"gates" => gates}) do
    Enum.find_value(gates, fn
      %{"status" => "failed", "failure_detail" => detail} when is_binary(detail) -> detail
      _gate -> nil
    end)
  end

  defp failed_gate_detail(_summary), do: nil

  defp validate_correlation(payload, correlation) do
    validate_correlation_fields(Map.get(payload, "correlation", %{}), correlation)
  end

  defp validate_correlation_fields(supplied, authoritative) do
    Enum.reduce_while(supplied, :ok, fn {key, value}, :ok ->
      if Map.has_key?(authoritative, key) and authoritative[key] != value,
        do: {:halt, {:error, {:correlation_mismatch, key}}},
        else: {:cont, :ok}
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp maybe_put_summary(payload, nil), do: payload
  defp maybe_put_summary(payload, summary), do: Map.put(payload, "summary", summary)
  defp map_get(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)
  defp process_alive?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp process_alive?(server) when is_pid(server), do: Process.alive?(server)

  defp notify_orchestrator(state, assignment, "task.progress", payload, _summary) do
    Orchestrator.worker_task_progress(assignment.issue.id, payload, state.orchestrator)
  end

  defp notify_orchestrator(state, assignment, event_type, _payload, summary)
       when event_type in @terminal_events do
    notify_worker_terminal(state, assignment, WorkerResult.terminal_outcome(event_type, summary))
  end

  defp notify_orchestrator(_state, _assignment, _event_type, _payload, _summary), do: :ok

  defp notify_worker_terminal(state, assignment, outcome) do
    Orchestrator.worker_task_finished(assignment.issue.id, outcome, state.orchestrator)
  end

  defp event_payload_with_time(payload, event) do
    Map.put(payload, "occurred_at", Map.get(event, :occurred_at))
  end

  defp inactive_heartbeat(worker_id, session_id) do
    with {:ok, base} <- PersistenceProvider.module().heartbeat_worker(worker_id, session_id) do
      {:ok, Map.merge(base, %{lease_renewals: [], commands: []})}
    end
  end
end
