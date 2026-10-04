defmodule SymphonyElixir.Worker.AssignmentManager do
  @moduledoc """
  Owns the Panel's single ephemeral worker assignment.

  Every assignment starts from a fresh tracker candidate read and a second issue read. Nothing in
  PostgreSQL is treated as queued work; runs and events are history records only.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{
    BlockingDecision,
    Config,
    EnvironmentFailureCircuit,
    Orchestrator,
    PersistenceProvider,
    PromptBuilder,
    Redaction,
    RunAdmission,
    RunFailure,
    RunLifecycle,
    Tracker,
    WorkerResult,
    WorkflowStore
  }

  alias SymphonyElixir.AgentRunner.Policy
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{DispatchPolicy, Events}
  alias SymphonyElixir.Worker.HeartbeatHistory

  @terminal_events ["task.completed", "task.failed", "task.cancelled"]
  @initial_poll_seconds 5
  @backoff_poll_seconds 30
  @max_poll_seconds 60
  @heartbeat_timeout_ms 1_000
  @heartbeat_retry_after_seconds 1
  @tracker_io_timeout_ms 5_000
  @claim_call_timeout_ms @tracker_io_timeout_ms + 1_000
  @cancel_timeout_ms 30_000
  @cancel_call_timeout_ms @cancel_timeout_ms + 1_000

  @type assignment :: map()
  @type liveness_entry :: %{
          required(:worker) => map(),
          required(:session) => map(),
          required(:total_slots) => pos_integer(),
          required(:last_seen_at) => DateTime.t()
        }
  @type cancellation_result :: %{
          required(:status) => String.t(),
          required(:cancelled) => non_neg_integer(),
          required(:failed) => [map()],
          required(:tasks) => [map()],
          optional(:project_id) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec claim_with_policy(String.t(), String.t(), map(), Orchestrator.listening_mode(), pos_integer(), GenServer.server()) ::
          {:ok, assignment() | {:empty, pos_integer()}} | {:error, term()} | {:error, term(), pos_integer()}
  def claim_with_policy(worker_id, session_id, attrs, listening_mode, max_concurrent_agents, server \\ __MODULE__) do
    case claim_with_policy_evidence(worker_id, session_id, attrs, listening_mode, max_concurrent_agents, server) do
      {:ok, result, _evidence} -> {:ok, result}
      {:error, reason, seconds} -> {:error, reason, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec claim_with_policy_evidence(
          String.t(),
          String.t(),
          map(),
          Orchestrator.listening_mode(),
          pos_integer(),
          GenServer.server()
        ) ::
          {:ok, assignment() | {:empty, pos_integer()}, map()} | {:error, term()} | {:error, term(), pos_integer()}
  def claim_with_policy_evidence(
        worker_id,
        session_id,
        attrs,
        listening_mode,
        max_concurrent_agents,
        server \\ __MODULE__
      ) do
    if process_alive?(server),
      do: GenServer.call(server, {:claim, worker_id, session_id, attrs, listening_mode, max_concurrent_agents}, @claim_call_timeout_ms),
      else: {:ok, {:empty, @initial_poll_seconds}, admission_evidence(:worker_dispatch_disabled, listening_mode)}
  end

  @spec reject_claim(String.t(), String.t(), :not_listening) ::
          {:ok, {:empty, pos_integer()}, map()}
  def reject_claim(worker_id, session_id, :not_listening) do
    evidence = admission_evidence(:not_listening, :not_listening)
    log_admission_skip(:not_listening, worker_id, session_id, evidence)
    {:ok, {:empty, @initial_poll_seconds}, evidence}
  end

  @spec observe_session(map(), map(), GenServer.server()) :: :ok
  def observe_session(%{id: worker_id} = worker, %{id: session_id} = session, server \\ __MODULE__)
      when is_binary(worker_id) and is_binary(session_id) do
    if process_alive?(server), do: GenServer.call(server, {:observe_session, worker, session}, :infinity), else: :ok
  end

  @spec observe_liveness(String.t(), String.t(), map(), GenServer.server()) :: :ok
  def observe_liveness(worker_id, session_id, attrs, server \\ __MODULE__) do
    if process_alive?(server), do: GenServer.cast(server, {:observe_liveness, worker_id, session_id, attrs}), else: :ok
  end

  @spec available_worker_slots(GenServer.server()) :: non_neg_integer()
  def available_worker_slots(server \\ __MODULE__) do
    if process_alive?(server), do: GenServer.call(server, :available_worker_slots), else: 0
  end

  @spec heartbeat(String.t(), String.t(), map(), GenServer.server(), module()) :: {:ok, map()} | {:error, term()}
  def heartbeat(worker_id, session_id, attrs, server \\ __MODULE__, persistence \\ PersistenceProvider.module()) do
    active_ids = active_lease_ids(attrs)
    observe_liveness(worker_id, session_id, attrs, server)
    HeartbeatHistory.observe(worker_id, session_id, persistence)

    with {:ok, heartbeat} <- heartbeat_assignment(worker_id, session_id, active_ids, server) do
      {:ok,
       %{
         ok: true,
         server_time: DateTime.utc_now(),
         lease_renewals: Map.fetch!(heartbeat, :lease_renewals),
         commands: Map.fetch!(heartbeat, :commands)
       }}
    end
  end

  @spec record_event(String.t(), String.t(), String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def record_event(worker_id, session_id, assignment_id, event_type, payload, server \\ __MODULE__),
    do: record_event_with_liveness(worker_id, session_id, assignment_id, event_type, payload, %{}, server)

  @spec record_event_with_liveness(String.t(), String.t(), String.t(), String.t(), map(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def record_event_with_liveness(worker_id, session_id, assignment_id, event_type, payload, attrs, server \\ __MODULE__) do
    if process_alive?(server),
      do: GenServer.call(server, {:event, worker_id, session_id, assignment_id, event_type, payload, attrs}),
      else: {:error, :lease_not_active}
  end

  @spec current_assignment(GenServer.server()) :: assignment() | nil
  def current_assignment(server \\ __MODULE__) do
    if process_alive?(server), do: GenServer.call(server, :current_assignment), else: nil
  end

  @spec cancel_current(String.t()) :: cancellation_result()
  def cancel_current(reason), do: cancel_current(reason, nil, __MODULE__)

  @spec cancel_current(String.t(), GenServer.server() | String.t() | nil) :: cancellation_result()
  def cancel_current(reason, server) when is_atom(server) or is_pid(server) or is_tuple(server) do
    cancel_current(reason, nil, server)
  end

  def cancel_current(reason, project_id) when is_binary(project_id) or is_nil(project_id) do
    cancel_current(reason, project_id, __MODULE__)
  end

  @spec cancel_current(String.t(), String.t() | nil, GenServer.server()) :: cancellation_result()
  def cancel_current(reason, project_id, server) when is_binary(project_id) or is_nil(project_id) do
    if process_alive?(server),
      do: GenServer.call(server, {:cancel_current, reason, project_id}, @cancel_call_timeout_ms),
      else: no_active_assignment(project_id)
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
      run_admission: Keyword.get(opts, :run_admission, RunAdmission),
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
      tracker_io_timeout_ms: Keyword.get(opts, :tracker_io_timeout_ms, @tracker_io_timeout_ms),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 10_000),
      claim_task: nil,
      reconcile_task: nil,
      empty_claim_streak: 0,
      tracker_error_streak: 0,
      liveness: %{}
    }

    schedule_reconciliation(state)
    {:ok, state}
  end

  @impl true
  def handle_cast(:reconcile, state), do: {:noreply, start_reconciliation(state)}

  def handle_cast({:claim_result, ref, result}, %{claim_task: %{ref: ref}} = state) do
    {:noreply, complete_claim(state, result)}
  end

  def handle_cast({:claim_result, _ref, _result}, state), do: {:noreply, state}

  def handle_cast({:reconcile_result, ref, result}, %{reconcile_task: %{ref: ref}} = state) do
    {:noreply, complete_reconciliation(state, result)}
  end

  def handle_cast({:reconcile_result, _ref, _result}, state), do: {:noreply, state}

  def handle_cast({:observe_liveness, worker_id, session_id, attrs}, state) do
    {:noreply, observe_request_liveness(state, worker_id, session_id, attrs)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = start_reconciliation(state)
    schedule_reconciliation(state)
    {:noreply, state}
  end

  def handle_info({:claim_timeout, ref}, %{claim_task: %{ref: ref} = task} = state) do
    _ = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)

    Logger.warning("event=worker_claim_tracker_timeout timeout_ms=#{state.tracker_io_timeout_ms}")

    {:noreply, complete_claim(state, {:error, {:linear_api_request, :timeout}})}
  end

  def handle_info({:claim_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:reconcile_timeout, ref}, %{reconcile_task: %{ref: ref} = task} = state) do
    _ = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)

    Logger.warning("event=worker_reconcile_tracker_timeout timeout_ms=#{state.tracker_io_timeout_ms}")

    {:noreply, %{state | reconcile_task: nil}}
  end

  def handle_info({:reconcile_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:cancel_timeout, ref}, %{assignment: %{cancellation: %{ref: ref} = cancellation} = assignment} = state) do
    result = failed_cancellation(assignment, cancellation_timeout_reason(cancellation), cancellation.project_id)
    reply_cancel_waiters(cancellation, result)
    cancellation = %{cancellation | waiters: [], timer: nil}
    {:noreply, %{state | assignment: %{assignment | cancellation: cancellation}}}
  end

  def handle_info({:cancel_timeout, _ref}, state), do: {:noreply, state}

  @impl true
  def handle_call(:current_assignment, _from, state), do: {:reply, state.assignment, state}

  def handle_call(:available_worker_slots, _from, state) do
    {:reply, fresh_liveness_capacity(state), state}
  end

  def handle_call({:observe_session, worker, session}, _from, state) do
    {:reply, :ok, observe_session_liveness(state, worker, session)}
  end

  def handle_call({:cancel_current, reason, project_id}, from, state) do
    state = expire_assignment(state)

    case matching_project_assignment(state.assignment, project_id) do
      {:ok, %{cancellation: cancellation} = assignment} ->
        {:noreply, %{state | assignment: %{assignment | cancellation: add_cancel_waiter(cancellation, from)}}}

      {:ok, assignment} ->
        {:noreply, %{state | assignment: Map.put(assignment, :cancellation, new_cancellation(reason, project_id, from))}}

      :error ->
        {:reply, no_active_assignment(project_id), state}
    end
  end

  def handle_call(
        {:claim, worker_id, session_id, attrs, listening_mode, _max_concurrent_agents},
        _from,
        %{claim_task: %{} = _claim_task} = state
      ) do
    state = observe_request_liveness(state, worker_id, session_id, attrs)
    evidence = admission_evidence(:active_assignment, listening_mode)
    {:reply, {:ok, {:empty, @initial_poll_seconds}, evidence}, state}
  end

  def handle_call({:claim, worker_id, session_id, attrs, listening_mode, max_concurrent_agents}, from, state) do
    state = expire_assignment(state)
    liveness = worker_session_liveness(state, worker_id, session_id)
    state = observe_request_liveness(state, worker_id, session_id, attrs)

    result =
      with {:ok, worker, session} <- liveness,
           true <- available_slots(attrs) > 0,
           :allow <- EnvironmentFailureCircuit.check(state.failure_circuit),
           nil <- state.assignment do
        {:claim, worker, session}
      else
        {:block, circuit} ->
          {:bypass, @max_poll_seconds, environment_failure_circuit_evidence(circuit, listening_mode)}

        %{} ->
          {:bypass, @initial_poll_seconds, admission_evidence(:active_assignment, listening_mode)}

        false ->
          {:bypass, @initial_poll_seconds, admission_evidence(:no_available_slots, listening_mode)}

        {:error, reason} when reason in [:worker_session_not_found, :worker_session_stale] ->
          {:bypass, @initial_poll_seconds, admission_evidence(reason, listening_mode)}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:claim, worker, session} ->
        {:noreply, start_claim(state, from, worker, session, listening_mode, max_concurrent_agents)}

      {:bypass, seconds, evidence} ->
        {:reply, {:ok, {:empty, seconds}, evidence}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:heartbeat, worker_id, session_id, active_ids, deadline_ms}, _from, state) do
    if System.monotonic_time(:millisecond) > deadline_ms do
      {:reply, heartbeat_unavailable(), state}
    else
      {assignment, heartbeat} = assignment_heartbeat(state.assignment, worker_id, session_id, active_ids, state)
      {:reply, {:ok, heartbeat}, %{state | assignment: assignment}}
    end
  end

  def handle_call({:event, worker_id, session_id, assignment_id, event_type, payload, attrs}, _from, state) do
    state = expire_assignment(state)
    state = observe_request_liveness(state, worker_id, session_id, attrs)

    case matching_assignment(state.assignment, worker_id, session_id, assignment_id) do
      {:ok, assignment} ->
        with :ok <- validate_correlation(payload, assignment.correlation),
             {:ok, summary} <- WorkerResult.validate_event(event_type, payload),
             terminal = terminal_result(event_type, summary),
             terminal_payload = terminal_event_payload(payload, terminal),
             {:ok, event} <- persist_event(state.persistence, assignment, event_type, terminal_payload, summary),
             :ok <- transition_run(state.persistence, assignment.run_id, event_type, terminal, summary),
             :ok <- persist_terminal_run_event(state.persistence, assignment, event_type, terminal, summary) do
          record_environment_failure_circuit(state, assignment, event_type, terminal)
          notify_orchestrator(state, assignment, event_type, event_payload_with_time(payload, event), terminal)
          state = complete_pending_cancellation(state, assignment, event_type, :ok)
          {:reply, {:ok, event}, %{state | assignment: assignment_after_event(state, event_type)}}
        else
          {:error, {:invalid_worker_summary, _message} = reason} when event_type in @terminal_events ->
            state = remember_terminal_rejection(state, assignment, event_type, payload, reason)
            state = complete_pending_cancellation(state, state.assignment, event_type, {:error, reason})
            {:reply, {:error, reason}, state}

          {:error, reason} ->
            state = complete_pending_cancellation(state, assignment, event_type, {:error, reason})
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_claim(state, from, worker, session, listening_mode, max_concurrent_agents) do
    manager = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        result = claim_from_workflows(state, worker, session, listening_mode, max_concurrent_agents)
        GenServer.cast(manager, {:claim_result, ref, result})
      end)

    timer = Process.send_after(manager, {:claim_timeout, ref}, state.tracker_io_timeout_ms)
    %{state | claim_task: %{ref: ref, pid: pid, timer: timer, from: from, listening_mode: listening_mode}}
  end

  defp complete_claim(%{claim_task: task} = state, result) do
    _ = Process.cancel_timer(task.timer)
    state = %{state | claim_task: nil}
    {reply, state} = claim_result(result, task.listening_mode, state)
    GenServer.reply(task.from, reply)
    state
  end

  defp claim_result({:ok, %{} = assignment}, listening_mode, state) do
    Orchestrator.worker_task_started(assignment, state.orchestrator)
    evidence = admission_evidence(:assigned, listening_mode)
    state = %{state | assignment: assignment, empty_claim_streak: 0, tracker_error_streak: 0}
    {{:ok, assignment, evidence}, state}
  end

  defp claim_result({:ok, nil, evidence}, _listening_mode, state) do
    streak = state.empty_claim_streak + 1
    seconds = empty_poll_seconds(streak)
    state = %{state | empty_claim_streak: streak, tracker_error_streak: 0}
    {{:ok, {:empty, seconds}, evidence}, state}
  end

  defp claim_result({:error, reason} = error, _listening_mode, state) do
    if tracker_backoff_error?(reason) do
      streak = state.tracker_error_streak + 1
      seconds = failure_poll_seconds(streak)
      {{:error, reason, seconds}, %{state | tracker_error_streak: streak}}
    else
      {error, state}
    end
  end

  defp claim_from_workflows(state, worker, session, listening_mode, max_concurrent_agents) do
    empty = {:ok, nil, admission_evidence(:no_eligible_candidate, listening_mode)}

    Enum.reduce_while(state.workflows.list_enabled(), empty, fn workflow, {:ok, nil, evidence} ->
      result =
        Config.with_workflow_context(workflow, fn ->
          dispatch_settings = Orchestrator.dispatch_policy_settings(listening_mode, max_concurrent_agents)
          claim_from_workflow(state, worker, session, workflow, dispatch_settings)
        end)

      case result do
        {:ok, nil, next_evidence} -> {:cont, {:ok, nil, merge_empty_evidence(evidence, next_evidence)}}
        {:ok, %{} = assignment} -> {:halt, {:ok, assignment}}
        {:error, _reason} = error -> {:halt, error}
      end
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

  defp claim_from_workflow(state, worker, session, workflow, dispatch_settings) do
    with {:ok, candidates} <- state.tracker.fetch_candidate_issues(),
         {:ok, %Issue{} = candidate} <-
           select_candidate(candidates, state.persistence, state.orchestrator, dispatch_settings),
         {:ok, %Issue{} = issue} <-
           revalidate(candidate, state.tracker, state.persistence, state.orchestrator, dispatch_settings),
         {:ok, assignment} <- create_assignment(state, worker, session, workflow, issue) do
      {:ok, assignment}
    else
      {:skip, reason, evidence} ->
        log_admission_skip(reason, worker.id, session.id, evidence)
        {:ok, nil, evidence}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_candidate(candidates, persistence, orchestrator, dispatch_settings) do
    listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

    candidates
    |> DispatchPolicy.sort_issues_for_dispatch()
    |> Enum.reduce_while(
      {:skip, :no_eligible_candidate, admission_evidence(:no_eligible_candidate, listening_mode)},
      fn issue, skip ->
        case candidate_admission(
               issue,
               persistence,
               orchestrator,
               dispatch_settings,
               "candidate_selection"
             ) do
          :ok -> {:halt, {:ok, issue}}
          {:skip, :blocking_decision, _evidence} = blocking -> {:cont, merge_candidate_skip(skip, blocking)}
          {:skip, :listening_mode, _evidence} = filtered -> {:cont, merge_candidate_skip(skip, filtered)}
          {:skip, _reason, _evidence} -> {:cont, skip}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp candidate_admission(%Issue{} = issue, persistence, orchestrator, dispatch_settings, clear_source) do
    listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

    with true <- DispatchPolicy.allowed_by_listening_mode?(issue.state, dispatch_settings),
         :ok <- live_issue_admission(issue, listening_mode),
         :ok <-
           blocking_decision_admission(
             issue,
             persistence,
             orchestrator,
             listening_mode,
             clear_source
           ) do
      if dispatchable_from_history?(issue, persistence),
        do: :ok,
        else: {:skip, :run_history, admission_evidence(:run_history, listening_mode)}
    else
      false ->
        {:skip, :listening_mode, admission_evidence(:listening_mode, listening_mode)}

      other ->
        other
    end
  end

  defp dispatchable_from_history?(%Issue{} = issue, persistence) do
    if worker_started_state?(issue.state) do
      case persistence.list_runs_for_issue(issue.identifier, limit: 1) do
        [%{status: status} | _] -> status in ["succeeded", "failed", "cancelled"]
        [] -> false
        {:error, _reason} -> false
      end
    else
      true
    end
  end

  defp live_issue_admission(%Issue{} = issue, listening_mode) do
    normalized = SymphonyElixir.StateName.normalize(issue.state)
    active = Config.settings!().tracker.active_states |> DispatchPolicy.normalized_state_set()

    cond do
      not MapSet.member?(active, normalized) -> {:skip, :stale, admission_evidence(:stale, listening_mode)}
      issue.blocked_by != [] -> {:skip, :dependency, admission_evidence(:dependency, listening_mode)}
      Config.human_review_state?(issue.state) -> {:skip, :human_review, admission_evidence(:human_review, listening_mode)}
      true -> :ok
    end
  end

  defp blocking_decision_admission(
         %Issue{} = issue,
         persistence,
         orchestrator,
         listening_mode,
         clear_source
       ) do
    case persistence.get_issue_by_identifier(issue.identifier) do
      %{blocking_decision: %{} = decision} ->
        scoped_blocking_decision_admission(
          issue,
          decision,
          persistence,
          orchestrator,
          listening_mode,
          clear_source
        )

      %{} ->
        :ok

      nil ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scoped_blocking_decision_admission(
         issue,
         decision,
         persistence,
         orchestrator,
         listening_mode,
         clear_source
       ) do
    with {:ok, latest_run_id} <- latest_run_id(persistence, issue.identifier) do
      decision
      |> BlockingDecision.validity(issue.state, latest_run_id)
      |> apply_blocking_decision_validity(
        issue,
        decision,
        persistence,
        orchestrator,
        listening_mode,
        clear_source
      )
    end
  end

  defp apply_blocking_decision_validity(
         :valid,
         issue,
         decision,
         _persistence,
         _orchestrator,
         listening_mode,
         _clear_source
       ) do
    {:skip, :blocking_decision, blocking_decision_evidence(issue, decision, listening_mode)}
  end

  defp apply_blocking_decision_validity(
         {:stale, cause},
         issue,
         decision,
         persistence,
         orchestrator,
         listening_mode,
         clear_source
       ) do
    clear_stale_blocking_decision(
      issue,
      decision,
      clear_source,
      cause,
      persistence,
      orchestrator,
      listening_mode
    )
  end

  defp latest_run_id(persistence, identifier) do
    case persistence.list_runs_for_issue(identifier, limit: 1) do
      [%{id: run_id} | _runs] -> {:ok, run_id}
      [] -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_stale_blocking_decision(
         issue,
         decision,
         source,
         cause,
         persistence,
         orchestrator,
         listening_mode
       ) do
    case BlockingDecision.clear_stale(
           issue.identifier,
           decision,
           source,
           cause,
           persistence
         ) do
      {:ok, _event} ->
        Orchestrator.blocking_decision_cleared(
          issue.id,
          decision["run_id"],
          orchestrator
        )

        Logger.info(
          "event=blocking_decision_cleared issue_id=#{issue.id} issue_identifier=#{issue.identifier} clear_source=#{source} clear_cause=#{cause} blocking_reason=#{inspect(decision["reason"])} origin_state=#{inspect(decision["origin_state"])} run_id=#{inspect(decision["run_id"])} decided_at=#{inspect(decision["decided_at"])}"
        )

        :ok

      :replaced ->
        blocking_decision_admission(
          issue,
          persistence,
          orchestrator,
          listening_mode,
          source
        )

      {:error, reason} ->
        {:error, {:blocking_decision_clear_failed, reason}}
    end
  end

  defp revalidate(%Issue{id: issue_id}, tracker, persistence, orchestrator, dispatch_settings) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        case candidate_admission(
               issue,
               persistence,
               orchestrator,
               dispatch_settings,
               "tracker_revalidation"
             ) do
          :ok -> {:ok, issue}
          other -> other
        end

      {:ok, []} ->
        {:skip, :missing, admission_evidence(:missing, DispatchPolicy.listening_mode(dispatch_settings))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_assignment(state, worker, session, workflow, issue) do
    authority = {:http_worker, worker.id, session.id}

    with {:ok, admission} <-
           state.run_admission.resolve(
             workflow,
             {:issue, issue},
             %{workspace_authority: authority, readiness: :ready}
           ) do
      create_admitted_assignment(state, worker, session, workflow, issue, admission)
    end
  end

  defp create_admitted_assignment(state, worker, session, workflow, issue, admission) do
    now = state.now.()
    assignment_id = Ecto.UUID.generate()
    expires_at = DateTime.add(now, state.persistence.worker_lease_duration_seconds(), :second)
    project_id = workflow.project_id
    profile = Config.workflow_profile_for_state(issue.state)

    with {:ok, issue_record} <-
           state.persistence.upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id)),
         {:ok, run} <- create_run(state.persistence, issue, admission, issue_record.id, project_id, now),
         {:ok, issue} <- move_to_worker_started(state.tracker, issue, profile),
         prompt <-
           PromptBuilder.build_prompt(issue,
             profile: profile,
             profile_policy: Config.workflow_profile(profile),
             allowed_updates: Config.workflow_allowed_updates(profile)
           ),
         assignment <-
           build_assignment(assignment_id, issue, run, worker, session, admission,
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

  defp create_run(persistence, issue, admission, issue_id, project_id, started_at) do
    attrs =
      issue
      |> Events.run_attrs(admission, nil)
      |> Map.merge(%{issue_id: issue_id, project_id: project_id, status: "running", started_at: started_at})

    persistence.create_run(attrs)
  end

  defp move_to_worker_started(tracker, %Issue{} = issue, profile) do
    with {:ok, started_state} <- Policy.worker_started_state(profile) do
      maybe_transition_to_worker_started(tracker, issue, profile, started_state)
    end
  end

  defp maybe_transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
    if same_issue_state?(issue.state, started_state) do
      {:ok, %{issue | state: started_state}}
    else
      transition_to_worker_started(tracker, issue, profile, started_state)
    end
  end

  defp transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
    transitions = Config.settings!().workflow |> Map.get("allowed_transitions", [])

    with :ok <- Policy.validate_worker_start_transition(transitions, issue.state, profile),
         :ok <- tracker.update_issue_state(issue.id, started_state) do
      {:ok, %{issue | state: started_state}}
    end
  end

  defp build_assignment(id, issue, run, worker, session, admission, opts) do
    payload = Events.worker_assignment_payload(issue, run, admission, opts[:prompt], opts[:profile]).payload

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
      admission: admission,
      started_at: Map.get(run, :started_at),
      expires_at: opts[:expires_at],
      payload: payload,
      correlation: correlation,
      last_terminal_rejection: nil
    }
  end

  defp worker_started_state?(state) when is_binary(state) do
    started_states = Policy.worker_started_states() |> DispatchPolicy.normalized_state_set()
    MapSet.member?(started_states, SymphonyElixir.StateName.normalize(state))
  end

  defp worker_started_state?(_state), do: false

  defp same_issue_state?(left, right) when is_binary(left) and is_binary(right) do
    SymphonyElixir.StateName.normalize(left) == SymphonyElixir.StateName.normalize(right)
  end

  defp assignment_heartbeat(nil, _worker_id, _session_id, _active_ids, _state),
    do: {nil, %{lease_renewals: [], commands: []}}

  defp assignment_heartbeat(assignment, worker_id, session_id, active_ids, state) do
    if active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
      heartbeat_active_assignment(assignment, state)
    else
      {assignment, %{lease_renewals: [], commands: []}}
    end
  end

  defp active_heartbeat_assignment?(assignment, worker_id, session_id, active_ids, state) do
    assignment.worker_id == worker_id and assignment.session_id == session_id and
      DateTime.compare(assignment.expires_at, state.now.()) in [:eq, :gt] and assignment.lease_id in active_ids
  end

  defp heartbeat_active_assignment(%{cancellation: _cancellation} = assignment, _state) do
    assignment = mark_cancel_delivered(assignment)
    {assignment, %{lease_renewals: [], commands: [cancel_command(assignment)]}}
  end

  defp heartbeat_active_assignment(assignment, state) do
    expires_at = DateTime.add(state.now.(), state.persistence.worker_lease_duration_seconds(), :second)
    renewal = %{lease_id: assignment.lease_id, lease_expires_at: expires_at}
    {%{assignment | expires_at: expires_at}, %{lease_renewals: [renewal], commands: []}}
  end

  defp expire_assignment(%{assignment: nil} = state), do: state

  defp expire_assignment(state) do
    if DateTime.compare(state.assignment.expires_at, state.now.()) == :lt do
      assignment = state.assignment
      failure = assignment_expiry_failure(assignment)

      _ = transition_run(state.persistence, assignment.run_id, "task.failed", failure, nil)
      _ = persist_terminal_run_event(state.persistence, assignment, "task.failed", failure, nil)

      _ =
        persist_event(
          state.persistence,
          assignment,
          "task.failed",
          terminal_event_payload(%{"reason" => "assignment_expired"}, failure),
          nil
        )

      notify_worker_terminal(state, assignment, {:failed, failure})
      %{state | assignment: nil}
    else
      state
    end
  end

  defp assignment_expiry_failure(%{last_terminal_rejection: nil}) do
    RunFailure.classify({:assignment_loss, %{reason: "assignment_expired", phase: "lease"}})
  end

  defp assignment_expiry_failure(%{last_terminal_rejection: rejection}) do
    RunFailure.classify({:assignment_expired, Map.put(rejection, "phase", "lease")})
  end

  defp remember_terminal_rejection(state, assignment, event_type, payload, {:invalid_worker_summary, message}) do
    rejection = %{
      "code" => "invalid_worker_summary",
      "validator_message" => message,
      "terminal_event_type" => event_type,
      "attempted" => attempted_terminal_metadata(payload)
    }

    %{state | assignment: %{assignment | last_terminal_rejection: rejection}}
  end

  defp attempted_terminal_metadata(payload) do
    payload
    |> map_get("summary", :summary)
    |> attempted_summary_metadata()
  end

  defp attempted_summary_metadata(summary) when is_map(summary) do
    metadata =
      [{"phase", :phase}, {"outcome", :outcome}, {"reason", :reason}, {"validation_status", :validation_status}]
      |> Enum.reduce(%{}, &put_attempted_metadata(&1, summary, &2))

    case map_get(summary, "gates", :gates) do
      gates when is_list(gates) -> Map.put(metadata, "gates", attempted_gate_metadata(gates))
      _other -> metadata
    end
  end

  defp attempted_summary_metadata(_summary), do: %{}

  defp attempted_gate_metadata(gates) do
    gates
    |> Enum.with_index()
    |> Enum.flat_map(&attempted_gate_metadata_entry/1)
  end

  defp attempted_gate_metadata_entry({gate, index}) when is_map(gate) do
    metadata =
      Enum.reduce(
        [{"status", :status}, {"exit_code", :exit_code}],
        %{"index" => index},
        &put_attempted_metadata(&1, gate, &2)
      )

    [metadata]
  end

  defp attempted_gate_metadata_entry({_gate, _index}), do: []

  defp put_attempted_metadata({string_key, atom_key}, source, values) do
    case sanitize_attempted_value(map_get(source, string_key, atom_key)) do
      nil -> values
      value -> Map.put(values, string_key, value)
    end
  end

  defp sanitize_attempted_value(value) when is_binary(value) do
    value
    |> WorkerResult.normalize_detail()
    |> Redaction.credentials()
  end

  defp sanitize_attempted_value(value) when is_integer(value), do: value
  defp sanitize_attempted_value(_value), do: nil

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

  defp transition_run(_persistence, _run_id, event_type, nil, _summary)
       when event_type not in @terminal_events,
       do: :ok

  defp transition_run(persistence, run_id, event_type, terminal, summary) do
    status = terminal_status(event_type, terminal, summary)
    attrs = if summary, do: %{execution_summary: summary}, else: %{}

    case RunLifecycle.finish_run(persistence, run_id, status, terminal, attrs: attrs) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_failed_run(persistence, identifier, reason) do
    case persistence.list_runs_for_issue(identifier, limit: 1) do
      [run | _] ->
        failure = RunFailure.classify({:claim_transition_failure, reason})
        persistence.finish_run(run.id, "failed", failure)

      _other ->
        :ok
    end
  end

  defp start_reconciliation(state) do
    state = expire_assignment(state)

    if state.reconcile_task do
      state
    else
      manager = self()
      ref = make_ref()
      workflows = state.workflows.list_enabled() |> Enum.uniq_by(&get_in(&1.config, ["tracker", "project_slug"]))

      {:ok, pid} =
        Task.Supervisor.start_child(state.task_supervisor, fn ->
          result = Enum.map(workflows, &reconcile_workflow_zombies(state, &1))
          GenServer.cast(manager, {:reconcile_result, ref, result})
        end)

      timer = Process.send_after(manager, {:reconcile_timeout, ref}, state.tracker_io_timeout_ms)
      %{state | reconcile_task: %{ref: ref, pid: pid, timer: timer}}
    end
  end

  defp complete_reconciliation(%{reconcile_task: task} = state, results) do
    _ = Process.cancel_timer(task.timer)

    Enum.each(results, fn
      {:error, project_slug, reason} ->
        Logger.warning("event=worker_reconcile_tracker_error project_slug=#{project_slug} reason=#{inspect(reason)}")

      {:ok, _project_slug} ->
        :ok
    end)

    %{state | reconcile_task: nil}
  end

  defp reconcile_workflow_zombies(state, workflow) do
    project_slug = get_in(workflow.config, ["tracker", "project_slug"])

    Config.with_workflow_context(workflow, fn ->
      fetch_and_reconcile_workflow_zombies(state, project_slug)
    end)
  end

  defp fetch_and_reconcile_workflow_zombies(state, project_slug) do
    case state.tracker.fetch_issues_by_states(["In Progress"]) do
      {:ok, issues} ->
        Enum.each(issues, &reconcile_zombie(state, &1))
        {:ok, project_slug}

      {:error, reason} ->
        {:error, project_slug, reason}
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
      failure = RunFailure.classify({:assignment_loss, %{reason: "panel_restart_or_worker_loss", phase: "reconciliation"}})

      with :ok <- state.tracker.update_issue_state(issue.id, "Ready"),
           {:ok, _run} <- state.persistence.finish_run(run.id, "failed", failure) do
        state.persistence.record_event(%{
          project_id: run.project_id,
          run_id: run.id,
          issue_identifier: issue.identifier,
          event_type: "task.failed",
          payload: terminal_event_payload(%{"reason" => "panel_restart_or_worker_loss"}, failure)
        })

        state.persistence.record_event(%{
          project_id: run.project_id,
          run_id: run.id,
          issue_identifier: issue.identifier,
          event_type: "run.failed",
          payload: terminal_event_payload(%{}, failure)
        })
      end
    end
  end

  defp maybe_requeue_zombie(_state, _issue, _run), do: :ok

  defp schedule_reconciliation(state) do
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
  end

  defp available_slots(attrs), do: map_get(attrs, "available_slots", :available_slots) || 0
  defp total_slots(attrs), do: map_get(attrs, "total_slots", :total_slots)

  defp worker_session_liveness(state, worker_id, session_id) do
    case Map.get(state.liveness, {worker_id, session_id}) do
      nil ->
        {:error, :worker_session_not_found}

      %{worker: worker, session: session} = entry ->
        if fresh_liveness?(state, entry), do: {:ok, worker, session}, else: {:error, :worker_session_stale}
    end
  end

  defp observe_request_liveness(state, worker_id, session_id, attrs) do
    case Map.get(state.liveness, {worker_id, session_id}) do
      nil -> observe_known_worker_session(state, worker_id, session_id, attrs)
      %{worker: worker, session: session} -> observe_session_liveness(state, worker, session, attrs)
    end
  end

  defp observe_known_worker_session(state, worker_id, session_id, attrs) do
    case state.persistence.worker_session_identity(worker_id, session_id) do
      {:ok, worker, session} -> observe_session_liveness(state, worker, session, attrs)
      {:error, _reason} -> state
    end
  end

  defp observe_session_liveness(state, worker, session, attrs \\ %{}) do
    total_slots = total_slots(attrs) || Map.fetch!(session, :total_slots)
    worker_id = Map.fetch!(worker, :id)
    session_id = Map.fetch!(session, :id)
    session = Map.put(session, :total_slots, total_slots)
    entry = %{worker: worker, session: session, total_slots: total_slots, last_seen_at: state.now.()}
    put_in(state.liveness[{worker_id, session_id}], entry)
  end

  defp fresh_liveness_capacity(state) do
    state.liveness
    |> Map.values()
    |> Enum.filter(&fresh_liveness?(state, &1))
    |> Enum.sum_by(& &1.total_slots)
  end

  defp fresh_liveness?(state, %{last_seen_at: last_seen_at}) do
    cutoff = DateTime.add(state.now.(), -liveness_timeout_seconds(state), :second)
    DateTime.compare(last_seen_at, cutoff) in [:eq, :gt]
  end

  defp liveness_timeout_seconds(state) do
    state.persistence.worker_heartbeat_interval_seconds() * 3
  end

  defp admission_evidence(reason, listening_mode) do
    %{capacity: if(reason == :assigned, do: 1, else: 0), reason: reason, listening_mode: listening_mode}
  end

  defp blocking_decision_evidence(issue, decision, listening_mode) do
    :blocking_decision
    |> admission_evidence(listening_mode)
    |> Map.merge(%{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      blocking_decision: Map.take(decision, ["decided_at", "origin_state", "reason", "run_id"])
    })
  end

  defp merge_candidate_skip(_current, {:skip, :blocking_decision, evidence}), do: {:skip, :blocking_decision, evidence}
  defp merge_candidate_skip({:skip, :blocking_decision, _evidence} = current, _next), do: current
  defp merge_candidate_skip(_current, {:skip, :listening_mode, evidence}), do: {:skip, :listening_mode, evidence}

  defp merge_empty_evidence(%{reason: :blocking_decision} = evidence, _next_evidence), do: evidence
  defp merge_empty_evidence(_evidence, %{reason: :blocking_decision} = next_evidence), do: next_evidence
  defp merge_empty_evidence(%{reason: :listening_mode} = evidence, _next_evidence), do: evidence
  defp merge_empty_evidence(_evidence, %{reason: :listening_mode} = next_evidence), do: next_evidence
  defp merge_empty_evidence(evidence, _next_evidence), do: evidence

  defp log_admission_skip(:blocking_decision, worker_id, session_id, evidence) do
    blocking_reason = get_in(evidence, [:blocking_decision, "reason"])
    origin_state = get_in(evidence, [:blocking_decision, "origin_state"])
    run_id = get_in(evidence, [:blocking_decision, "run_id"])
    decided_at = get_in(evidence, [:blocking_decision, "decided_at"])

    Logger.info(
      "event=worker_claim_skip issue_id=#{evidence.issue_id} issue_identifier=#{evidence.issue_identifier} worker_id=#{worker_id} session_id=#{session_id} skip_reason=blocking_decision blocking_reason=#{inspect(blocking_reason)} origin_state=#{inspect(origin_state)} run_id=#{inspect(run_id)} decided_at=#{inspect(decided_at)} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}"
    )
  end

  defp log_admission_skip(reason, worker_id, session_id, evidence)
       when reason in [:not_listening, :listening_mode] do
    Logger.info("event=worker_claim_skip worker_id=#{worker_id} session_id=#{session_id} skip_reason=#{reason} listening_mode=#{evidence.listening_mode} capacity=#{evidence.capacity}")
  end

  defp log_admission_skip(_reason, _worker_id, _session_id, _evidence), do: :ok

  defp environment_failure_circuit_evidence(circuit, listening_mode) do
    :environment_failure_circuit_open
    |> admission_evidence(listening_mode)
    |> Map.put(:failure_fingerprint, circuit.triggering_fingerprint)
  end

  defp record_environment_failure_circuit(state, assignment, "task.completed", _terminal) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(state, assignment, "task.cancelled", _terminal) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(state, assignment, "task.failed", :completed) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(
         state,
         assignment,
         "task.failed",
         %RunFailure{classification: "cancelled"}
       ) do
    EnvironmentFailureCircuit.record_success(assignment.issue_identifier, state.failure_circuit)
  end

  defp record_environment_failure_circuit(state, assignment, "task.failed", %RunFailure{} = failure) do
    circuit =
      EnvironmentFailureCircuit.record_failure(
        assignment.issue_identifier,
        RunFailure.reason(failure),
        %{issue_id: assignment.issue.id, run_id: assignment.run_id},
        state.failure_circuit
      )

    if circuit.alert do
      state.persistence.record_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, assignment.project_id))
    end
  end

  defp record_environment_failure_circuit(_state, _assignment, _event_type, _summary), do: :ok

  defp terminal_result(event_type, summary) when event_type in @terminal_events,
    do: RunFailure.from_worker_summary(event_type, summary)

  defp terminal_result(event_type, _summary) when event_type not in @terminal_events, do: nil

  defp terminal_status("task.completed", :completed, _summary), do: "completed"
  defp terminal_status("task.failed", :completed, _summary), do: "completed"
  defp terminal_status("task.failed", %RunFailure{classification: "cancelled"}, _summary), do: "cancelled"
  defp terminal_status("task.failed", %RunFailure{}, %{"outcome" => "blocked"}), do: "blocked"
  defp terminal_status("task.failed", %RunFailure{}, _summary), do: "failed"
  defp terminal_status("task.cancelled", %RunFailure{classification: "cancelled"}, _summary), do: "cancelled"

  defp persist_terminal_run_event(_persistence, _assignment, event_type, nil, _summary)
       when event_type not in @terminal_events,
       do: :ok

  defp persist_terminal_run_event(persistence, assignment, event_type, terminal, summary) do
    status = terminal_status(event_type, terminal, summary)
    fields = RunFailure.terminal_fields(terminal)

    attrs =
      assignment_event(assignment, "run.#{status}", %{
        "failure_reason" => fields.failure_reason,
        "failure_evidence" => fields.failure_evidence
      })

    case persistence.record_event(attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_event_payload(payload, nil), do: payload

  defp terminal_event_payload(payload, terminal) do
    fields = RunFailure.terminal_fields(terminal)

    payload
    |> Map.put("failure_reason", fields.failure_reason)
    |> Map.put("failure_evidence", fields.failure_evidence)
  end

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
  defp process_alive?(server), do: GenServer.whereis(server) != nil

  defp active_lease_ids(attrs), do: map_get(attrs, "active_leases", :active_leases) || []

  defp heartbeat_assignment(_worker_id, _session_id, [], _server), do: {:ok, %{lease_renewals: [], commands: []}}

  defp heartbeat_assignment(worker_id, session_id, active_ids, server) do
    if process_alive?(server) do
      deadline_ms = System.monotonic_time(:millisecond) + @heartbeat_timeout_ms

      try do
        GenServer.call(server, {:heartbeat, worker_id, session_id, active_ids, deadline_ms}, @heartbeat_timeout_ms)
      catch
        :exit, {:timeout, _call} -> heartbeat_unavailable()
      end
    else
      {:ok, %{lease_renewals: [], commands: []}}
    end
  end

  defp heartbeat_unavailable, do: {:error, {:heartbeat_unavailable, @heartbeat_retry_after_seconds}}

  defp matching_project_assignment(nil, _project_id), do: :error
  defp matching_project_assignment(assignment, nil), do: {:ok, assignment}
  defp matching_project_assignment(%{project_id: project_id} = assignment, project_id), do: {:ok, assignment}
  defp matching_project_assignment(_assignment, _project_id), do: :error

  defp new_cancellation(reason, project_id, from) do
    ref = make_ref()

    %{
      reason: reason,
      project_id: project_id,
      ref: ref,
      timer: Process.send_after(self(), {:cancel_timeout, ref}, @cancel_timeout_ms),
      waiters: [from],
      delivered?: false
    }
  end

  defp add_cancel_waiter(%{timer: nil} = cancellation, from) do
    ref = make_ref()

    %{
      cancellation
      | ref: ref,
        timer: Process.send_after(self(), {:cancel_timeout, ref}, @cancel_timeout_ms),
        waiters: [from]
    }
  end

  defp add_cancel_waiter(cancellation, from), do: %{cancellation | waiters: [from | cancellation.waiters]}

  defp mark_cancel_delivered(%{cancellation: cancellation} = assignment) do
    %{assignment | cancellation: %{cancellation | delivered?: true}}
  end

  defp cancel_command(%{id: task_id, cancellation: cancellation}) do
    %{"type" => "cancel_task", "task_id" => task_id, "reason" => cancellation.reason}
  end

  defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, "task.cancelled", :ok) do
    cancel_timer(cancellation)
    reply_cancel_waiters(cancellation, cancelled_assignment(assignment, cancellation.project_id))
    state
  end

  defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, event_type, :ok)
       when event_type in @terminal_events do
    cancel_timer(cancellation)
    result = failed_cancellation(assignment, :worker_terminal_not_cancelled, cancellation.project_id)
    reply_cancel_waiters(cancellation, result)
    state
  end

  defp complete_pending_cancellation(state, %{cancellation: cancellation} = assignment, event_type, {:error, reason})
       when event_type in @terminal_events do
    cancel_timer(cancellation)
    result = failed_cancellation(assignment, {:terminal_event_failed, reason}, cancellation.project_id)
    reply_cancel_waiters(cancellation, result)
    %{state | assignment: %{assignment | cancellation: %{cancellation | waiters: [], timer: nil}}}
  end

  defp complete_pending_cancellation(state, _assignment, _event_type, _result), do: state

  defp assignment_after_event(_state, event_type) when event_type in @terminal_events, do: nil
  defp assignment_after_event(state, _event_type), do: state.assignment

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)

  defp reply_cancel_waiters(%{waiters: waiters}, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
  end

  defp cancellation_timeout_reason(%{delivered?: true}), do: :worker_termination_timeout
  defp cancellation_timeout_reason(%{delivered?: false}), do: :worker_cancel_delivery_timeout

  defp no_active_assignment(project_id) do
    %{
      status: "no_active_assignment",
      cancelled: 0,
      failed: [],
      tasks: [],
      project_id: project_id
    }
  end

  defp cancelled_assignment(assignment, project_id) do
    %{
      status: "cancelled",
      cancelled: 1,
      failed: [],
      tasks: [assignment_result(assignment)],
      project_id: project_id
    }
  end

  defp failed_cancellation(assignment, reason, project_id) do
    %{
      status: "failed",
      cancelled: 0,
      failed: [Map.put(assignment_result(assignment), :reason, inspect(reason))],
      tasks: [],
      project_id: project_id
    }
  end

  defp assignment_result(assignment) do
    %{
      assignment_id: assignment.id,
      task_id: assignment.task_id,
      lease_id: assignment.lease_id,
      project_id: assignment.project_id,
      run_id: assignment.run_id,
      issue_id: assignment.issue.id,
      issue_identifier: assignment.issue_identifier,
      worker_id: assignment.worker_id,
      worker_session_id: assignment.session_id
    }
  end

  defp notify_orchestrator(state, assignment, "task.progress", payload, _summary) do
    if map_get(payload, "phase", :phase) == "source_preparation" do
      send(state.orchestrator, {:system_worker_update, assignment.issue.id, source_progress_update(payload)})
    else
      Orchestrator.worker_task_progress(assignment.issue.id, payload, state.orchestrator)
    end
  end

  defp notify_orchestrator(state, assignment, event_type, payload, terminal)
       when event_type in @terminal_events do
    outcome =
      case {event_type, terminal, get_in(payload, ["summary", "outcome"])} do
        {"task.completed", :completed, _outcome} ->
          :success

        {"task.cancelled", %RunFailure{}, _outcome} ->
          :cancelled

        {"task.failed", :completed, _outcome} ->
          :success

        {"task.failed", %RunFailure{classification: "cancelled"}, _outcome} ->
          :cancelled

        {"task.failed", %RunFailure{} = failure, "blocked"} ->
          {:blocked, failure}

        {"task.failed", %RunFailure{} = failure, _outcome} ->
          {:failed, failure}
      end

    notify_worker_terminal(state, assignment, outcome)
  end

  defp notify_orchestrator(_state, _assignment, _event_type, _payload, _summary), do: :ok

  defp source_progress_update(payload) do
    %{
      source: map_get(payload, "source", :source),
      phase: map_get(payload, "phase", :phase),
      operation: map_get(payload, "operation", :operation),
      status: map_get(payload, "status", :status),
      detail: map_get(payload, "detail", :detail),
      occurred_at: map_get(payload, "occurred_at", :occurred_at)
    }
  end

  defp notify_worker_terminal(state, assignment, outcome) do
    Orchestrator.worker_task_finished(assignment.issue.id, outcome, state.orchestrator)
  end

  defp event_payload_with_time(payload, event) do
    Map.put(payload, "occurred_at", Map.get(event, :occurred_at))
  end
end
