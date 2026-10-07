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
    Redaction,
    RunAdmission,
    RunFailure,
    Tracker,
    WorkerResult,
    WorkflowStore
  }

  alias SymphonyElixir.AgentRunner.Policy
  alias SymphonyElixir.Linear.{DispatchScope, Issue}
  alias SymphonyElixir.Orchestrator.DispatchPolicy
  alias SymphonyElixir.Worker.{ClaimCommit, ClaimStage, EventWriter, HeartbeatHistory}

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
    if process_alive?(server) do
      try do
        GenServer.call(server, {:claim, worker_id, session_id, attrs, listening_mode, max_concurrent_agents}, @claim_call_timeout_ms)
      catch
        :exit, {:timeout, _call} -> {:error, :claim_pending, @initial_poll_seconds}
      end
    else
      {:ok, {:empty, @initial_poll_seconds}, admission_evidence(:worker_dispatch_disabled, listening_mode)}
    end
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
      do: call_event(server, worker_id, session_id, assignment_id, event_type, payload, attrs),
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
      event_task: nil,
      empty_claim_streak: 0,
      tracker_error_streak: 0,
      liveness: %{}
    }

    schedule_reconciliation(state)
    {:ok, state}
  end

  @impl true
  def handle_cast(:reconcile, state), do: {:noreply, start_reconciliation(state)}

  def handle_cast({:claim_stage, id, stage, started}, %{claim_task: %{claim_id: id} = task} = state) do
    {:noreply, %{state | claim_task: %{task | stage: stage, stage_started: started}}}
  end

  def handle_cast({:claim_stage, _id, _stage, _started}, state), do: {:noreply, state}

  def handle_cast({:reconcile_result, ref, result}, %{reconcile_task: %{ref: ref}} = state) do
    {:noreply, complete_reconciliation(state, result)}
  end

  def handle_cast({:reconcile_result, _ref, _result}, state), do: {:noreply, state}

  def handle_cast({:observe_liveness, worker_id, session_id, attrs}, state) do
    {:noreply, observe_request_liveness(state, worker_id, session_id, attrs)}
  end

  @impl true
  def handle_info({ref, result}, %{event_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_event_write(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{event_task: %{ref: ref}} = state) do
    {:noreply, finish_event_write(state, {:error, {:event_writer_exit, reason}})}
  end

  def handle_info({:retry_terminal_write, ref}, %{event_task: %{ref: ref} = operation} = state) do
    admission = admit_worker_event(state, operation.request)
    {:noreply, start_event_write(state, operation.request, admission, nil, :event)}
  end

  def handle_info(:reconcile, state) do
    state = start_reconciliation(state)
    schedule_reconciliation(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{claim_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_claim_task(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{claim_task: %{ref: ref, phase: :prepare}} = state) do
    Logger.error("event=worker_claim_prepare_failed claim_id=#{state.claim_task.claim_id} stage=#{state.claim_task.stage} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
    {:noreply, complete_claim(state, {:error, {:claim_prepare_failed, state.claim_task.stage, reason}})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{claim_task: %{ref: ref, phase: :commit}} = state) do
    {:noreply, retry_claim_commit(state, state.claim_task.operation, {:task_exit, reason})}
  end

  def handle_info({:claim_timeout, id}, %{claim_task: %{claim_id: id, phase: :prepare} = task} = state) do
    _ = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    Process.demonitor(task.ref, [:flush])

    Logger.warning(
      "event=worker_claim_prepare_timeout claim_id=#{id} stage=#{task.stage} timeout_ms=#{state.tracker_io_timeout_ms} elapsed_ms=#{System.monotonic_time(:millisecond) - task.stage_started}"
    )

    {:noreply, complete_claim(state, {:error, {:claim_prepare_timeout, task.stage}})}
  end

  def handle_info({:claim_timeout, _id}, state), do: {:noreply, state}

  def handle_info({:retry_claim_commit, ref}, %{claim_task: %{ref: ref} = task} = state) do
    {:noreply, start_claim_commit(state, task.operation)}
  end

  def handle_info({:retry_claim_commit, _ref}, state), do: {:noreply, state}

  def handle_info({:reconcile_timeout, ref}, %{reconcile_task: %{ref: ref} = task} = state) do
    _ = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)

    Logger.warning("event=worker_reconcile_tracker_timeout timeout_ms=#{state.tracker_io_timeout_ms}")

    Enum.each(task.workflows, fn workflow ->
      record_linear_request_failure(state.persistence, workflow, "worker_reconcile", {:linear_api_request, :timeout})
    end)

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

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref), do: {:noreply, state}

  @impl true
  def handle_call(:current_assignment, _from, state), do: {:reply, state.assignment, state}

  def handle_call(:available_worker_slots, _from, state) do
    {:reply, fresh_liveness_capacity(state), state}
  end

  def handle_call({:observe_session, worker, session}, _from, state) do
    {:reply, :ok, observe_session_liveness(state, worker, session)}
  end

  def handle_call({:cancel_current, _reason, nil}, _from, %{claim_task: %{phase: :prepare} = task} = state) do
    Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    Process.demonitor(task.ref, [:flush])
    state = complete_claim(state, {:error, :claim_cancelled})
    {:reply, no_active_assignment(nil), state}
  end

  def handle_call({:cancel_current, _reason, project_id}, _from, %{claim_task: %{phase: :prepare} = task} = state) do
    result = %{
      status: "failed",
      cancelled: 0,
      failed: [%{assignment_id: task.claim_id, reason: "claim_prepare_pending"}],
      tasks: [],
      project_id: project_id
    }

    {:reply, result, state}
  end

  def handle_call({:cancel_current, _reason, project_id}, _from, %{claim_task: %{phase: :commit} = task} = state) do
    prepared = elem(task.operation, 1)

    result =
      if is_nil(project_id) or project_id == prepared.workflow.project_id do
        %{
          status: "failed",
          cancelled: 0,
          failed: [%{assignment_id: task.claim_id, run_id: prepared.run_id, issue_identifier: prepared.issue.identifier, reason: "claim_commit_pending"}],
          tasks: [],
          project_id: project_id
        }
      else
        no_active_assignment(project_id)
      end

    {:reply, result, state}
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
      with :new <- replay_assignment(state, worker_id, session_id, attrs),
           {:ok, worker, session} <- liveness,
           true <- available_slots(attrs) > 0,
           :allow <- EnvironmentFailureCircuit.check(state.failure_circuit),
           nil <- state.assignment do
        {:claim, worker, session}
      else
        {:replay, assignment} ->
          {:replay, assignment}

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
      {:replay, assignment} ->
        {:reply, {:ok, assignment, admission_evidence(:assigned, listening_mode)}, state}

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

  def handle_call({:event, _worker_id, _session_id, _assignment_id, _event_type, _payload, _attrs}, _from, %{event_task: %{kind: :expiry}} = state) do
    {:reply, {:error, :lease_not_active}, state}
  end

  def handle_call({:event, _worker_id, _session_id, _assignment_id, _event_type, _payload, _attrs}, _from, %{event_task: %{}} = state) do
    {:reply, {:error, :event_write_busy}, state}
  end

  def handle_call({:event, worker_id, session_id, assignment_id, event_type, payload, attrs}, from, state) do
    state = expire_assignment(state)
    state = observe_request_liveness(state, worker_id, session_id, attrs)

    request = %{
      id: Map.fetch!(payload, "event_id"),
      worker_id: worker_id,
      session_id: session_id,
      assignment_id: assignment_id,
      event_type: event_type,
      payload: Map.delete(payload, "event_id")
    }

    if state.event_task,
      do: {:reply, {:error, :lease_not_active}, state},
      else: prepare_event_write(state, request, from)
  end

  defp prepare_event_write(state, request, from) do
    admission = admit_worker_event(state, request)

    case WorkerResult.validate_event(request.event_type, request.payload) do
      {:ok, summary} ->
        request = Map.merge(request, %{summary: summary, terminal: terminal_result(request.event_type, summary)})
        {:noreply, start_event_write(state, request, admission, from, :event)}

      {:error, reason} ->
        state = reject_event(state, request, reason)

        result =
          case admission do
            {:ok, _assignment} -> {:error, reason}
            {:error, _reason} = error -> error
          end

        {:reply, result, state}
    end
  end

  defp admit_worker_event(state, request) do
    id = request.assignment_id

    with {:ok, assignment} <- matching_assignment(state.assignment, request.worker_id, request.session_id, id),
         :ok <- validate_correlation(request.payload, assignment.correlation) do
      {:ok, assignment}
    end
  end

  defp call_event(server, worker_id, session_id, assignment_id, event_type, payload, attrs) do
    payload = payload |> Jason.encode!() |> Jason.decode!() |> Map.put_new_lazy("event_id", &Ecto.UUID.generate/0)

    case Ecto.UUID.cast(payload["event_id"]) do
      {:ok, id} ->
        try do
          GenServer.call(server, {:event, worker_id, session_id, assignment_id, event_type, Map.put(payload, "event_id", id), attrs})
        catch
          :exit, {:timeout, _call} -> {:error, :event_write_timeout}
        end

      :error ->
        {:error, :invalid_event_id}
    end
  end

  defp reject_event(state, %{event_type: type} = request, {:invalid_worker_summary, _message} = reason)
       when type in @terminal_events do
    case admit_worker_event(state, request) do
      {:ok, assignment} ->
        state = remember_terminal_rejection(state, assignment, type, request.payload, reason)
        complete_pending_cancellation(state, state.assignment, type, {:error, reason})

      {:error, _reason} ->
        state
    end
  end

  defp reject_event(state, _request, _reason), do: state

  defp start_event_write(state, request, admission, from, kind) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        result = EventWriter.write(state.persistence, request, admission)

        case {kind, result, admission} do
          {:event, {:ok, {_event, :written}}, {:ok, assignment}} ->
            record_environment_failure_circuit(state, assignment, request.event_type, request.terminal)

          _ ->
            :ok
        end

        result
      end)

    %{state | event_task: %{ref: task.ref, request: request, from: from, kind: kind}}
  end

  defp finish_event_write(state, {:ok, {event, _disposition}}) do
    operation = state.event_task
    request = operation.request
    state = %{state | event_task: nil}

    state =
      case state.assignment do
        %{id: id} = assignment when id == request.assignment_id ->
          payload = event_payload_with_time(request.payload, event)
          notify_orchestrator(state, assignment, request.event_type, payload, request.terminal)
          state = complete_pending_cancellation(state, assignment, request.event_type, :ok)
          %{state | assignment: assignment_after_event(state, request.event_type)}

        _ ->
          state
      end

    if operation.from, do: GenServer.reply(operation.from, {:ok, event})
    expire_assignment(state)
  end

  defp finish_event_write(state, {:error, reason}) do
    operation = state.event_task
    request = operation.request

    Logger.error(
      "event=worker_event_write_failed #{event_write_context(state.assignment, request.assignment_id)} task_id=#{request.assignment_id} worker_id=#{request.worker_id} worker_session_id=#{request.session_id} event_id=#{request.id} event_type=#{request.event_type} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}"
    )

    if operation.from, do: GenServer.reply(operation.from, event_write_error(reason))
    state = %{state | event_task: nil}

    state =
      case admit_worker_event(state, request) do
        {:ok, assignment} -> complete_pending_cancellation(state, assignment, request.event_type, {:error, reason})
        {:error, _reason} -> state
      end

    retry_failed_terminal(state, operation, event_write_error(reason))
  end

  defp event_write_context(%{id: id} = assignment, id) do
    "issue_id=#{assignment.issue.id} issue_identifier=#{assignment.issue_identifier} run_id=#{assignment.run_id}"
  end

  defp event_write_context(_assignment, _id), do: "issue_id=n/a issue_identifier=n/a run_id=n/a"

  defp retry_failed_terminal(state, %{kind: :event, request: %{terminal: terminal}} = operation, {:error, {:event_write_failed, _reason}}) when not is_nil(terminal) do
    case admit_worker_event(state, operation.request) do
      {:ok, _assignment} ->
        Process.send_after(self(), {:retry_terminal_write, operation.ref}, 1_000)
        %{state | event_task: %{operation | from: nil}}

      {:error, _reason} ->
        state
    end
  end

  defp retry_failed_terminal(state, _operation, _error), do: state

  defp event_write_error(reason) when reason in [:lease_not_active, :event_id_conflict], do: {:error, reason}
  defp event_write_error({:correlation_mismatch, _field} = reason), do: {:error, reason}
  defp event_write_error(reason), do: {:error, {:event_write_failed, reason}}

  defp replay_assignment(%{assignment: %{worker_id: worker, session_id: session} = assignment, event_task: nil} = state, worker, session, attrs) do
    if available_slots(attrs) > 0 and not Map.has_key?(assignment, :cancellation) and DateTime.compare(assignment.expires_at, state.now.()) != :lt, do: {:replay, assignment}, else: :new
  end

  defp replay_assignment(_state, _worker, _session, _attrs), do: :new

  defp start_claim(state, from, worker, session, listening_mode, max_concurrent_agents) do
    id = Ecto.UUID.generate()
    context = %{manager: self(), claim_id: id, phase: :prepare, worker_id: worker.id, session_id: session.id, listening_mode: listening_mode}

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        claim_from_workflows(Map.put(state, :claim_context, context), worker, session, listening_mode, max_concurrent_agents)
      end)

    timer = Process.send_after(self(), {:claim_timeout, id}, state.tracker_io_timeout_ms)

    job = %{
      ref: task.ref,
      pid: task.pid,
      claim_id: id,
      timer: timer,
      from: from,
      listening_mode: listening_mode,
      phase: :prepare,
      operation: nil,
      context: context,
      stage: :workflows,
      stage_started: System.monotonic_time(:millisecond)
    }

    %{state | claim_task: job}
  end

  defp finish_claim_task(%{claim_task: %{phase: :prepare}} = state, {:ok, %{} = prepared}) do
    Process.cancel_timer(state.claim_task.timer)
    prepared = Map.merge(prepared, %{assignment_id: state.claim_task.claim_id, run_id: Ecto.UUID.generate(), event_id: Ecto.UUID.generate()})
    start_claim_commit(state, {:activate, prepared})
  end

  defp finish_claim_task(state, {:retry, operation, reason}), do: retry_claim_commit(state, operation, reason)
  defp finish_claim_task(state, result), do: complete_claim(state, result)

  defp start_claim_commit(state, operation) do
    job = state.claim_task
    context = %{job.context | phase: :commit}
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> ClaimCommit.run(state, operation, context) end)
    %{state | claim_task: %{job | ref: task.ref, pid: task.pid, timer: nil, phase: :commit, operation: operation, context: context}}
  end

  defp retry_claim_commit(state, operation, reason) do
    job = state.claim_task
    Logger.warning("event=worker_claim_commit_retry claim_id=#{job.claim_id} stage=#{job.stage} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")
    streak = state.tracker_error_streak + 1
    seconds = failure_poll_seconds(streak)
    if job.from, do: GenServer.reply(job.from, {:error, :claim_pending, seconds})
    Process.send_after(self(), {:retry_claim_commit, job.ref}, seconds * 1_000)
    %{state | claim_task: %{job | operation: operation, from: nil}, tracker_error_streak: streak}
  end

  defp complete_claim(%{claim_task: task} = state, result) do
    if task.timer, do: Process.cancel_timer(task.timer)
    {reply, state} = claim_result(result, task.listening_mode, %{state | claim_task: nil})
    if task.from, do: GenServer.reply(task.from, reply)
    state
  end

  defp claim_result({:ok, %{} = assignment}, listening_mode, state) do
    expires_at = DateTime.add(state.now.(), state.persistence.worker_lease_duration_seconds(), :second)
    assignment = %{assignment | expires_at: expires_at}
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
    workflows = ClaimStage.measure(state.claim_context, :workflows, fn -> state.workflows.list_enabled() end)
    claim_with_workflows(workflows, empty, state, worker, session, listening_mode, max_concurrent_agents)
  end

  defp claim_with_workflows([], empty, _state, _worker, _session, _mode, _capacity), do: empty

  defp claim_with_workflows(
         [query_workflow | _rest] = workflows,
         _empty,
         state,
         worker,
         session,
         listening_mode,
         max_concurrent_agents
       ) do
    Config.with_workflow_context(query_workflow, fn ->
      claim_from_query_workflow(state, worker, session, workflows, listening_mode, max_concurrent_agents)
    end)
  end

  defp claim_from_query_workflow(state, worker, session, workflows, listening_mode, max_concurrent_agents) do
    with {:ok, candidates} <-
           ClaimStage.measure(state.claim_context, :candidate_fetch, fn ->
             state.tracker.fetch_candidate_issues()
           end),
         {:ok, workflow, candidate, dispatch_settings} <-
           select_scoped_candidate(candidates, workflows, state, listening_mode, max_concurrent_agents) do
      Config.with_workflow_context(workflow, fn ->
        claim_scoped_candidate(state, worker, session, workflow, candidate, workflows, dispatch_settings)
      end)
    else
      {:skip, reason, evidence} ->
        log_admission_skip(reason, worker.id, session.id, evidence)
        {:ok, nil, evidence}

      {:error, _reason} = error ->
        error
    end
  end

  defp empty_poll_seconds(1), do: @initial_poll_seconds
  defp empty_poll_seconds(streak) when streak in 2..5, do: @backoff_poll_seconds
  defp empty_poll_seconds(_streak), do: @max_poll_seconds

  defp failure_poll_seconds(1), do: @backoff_poll_seconds
  defp failure_poll_seconds(_streak), do: @max_poll_seconds

  defp tracker_backoff_error?({:linear_api_status, status, _body}) when status == 429 or status in 500..599, do: true
  defp tracker_backoff_error?({:linear_api_request, _reason}), do: true
  defp tracker_backoff_error?({:claim_prepare_timeout, _stage}), do: true
  defp tracker_backoff_error?({:claim_prepare_failed, _stage, _reason}), do: true
  defp tracker_backoff_error?(_reason), do: false

  defp claim_scoped_candidate(
         state,
         worker,
         session,
         workflow,
         candidate,
         workflows,
         dispatch_settings
       ) do
    with {:ok, %Issue{} = issue} <-
           revalidate_scoped(candidate, workflow, workflows, state, dispatch_settings),
         {:ok, assignment} <- prepare_assignment(state, worker, session, workflow, issue) do
      {:ok, assignment}
    else
      {:skip, reason, evidence} ->
        log_admission_skip(reason, worker.id, session.id, evidence)
        {:ok, nil, evidence}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_scoped_candidate(
         candidates,
         workflows,
         state,
         listening_mode,
         max_concurrent_agents
       ) do
    scope = workflows |> hd() |> then(&Config.with_workflow_context(&1, fn -> Config.settings!().dispatch_scope end))
    empty = {:skip, :no_eligible_candidate, admission_evidence(:no_eligible_candidate, listening_mode)}

    candidates
    |> DispatchPolicy.sort_issues_for_dispatch()
    |> Enum.reduce_while(empty, fn issue, skip ->
      select_scoped_issue(
        DispatchScope.resolve(issue, workflows, scope),
        skip,
        state,
        listening_mode,
        max_concurrent_agents
      )
    end)
  end

  defp select_scoped_issue(
         {:ok, workflow, issue},
         skip,
         state,
         listening_mode,
         max_concurrent_agents
       ) do
    result =
      Config.with_workflow_context(workflow, fn ->
        admit_scoped_candidate(workflow, issue, state, listening_mode, max_concurrent_agents)
      end)

    continue_scoped_selection(result, skip)
  end

  defp select_scoped_issue({:error, reason, issue}, skip, _state, _mode, _capacity) do
    log_context_rejection(issue, reason)
    {:cont, skip}
  end

  defp admit_scoped_candidate(workflow, issue, state, listening_mode, max_concurrent_agents) do
    dispatch_settings = Orchestrator.dispatch_policy_settings(listening_mode, max_concurrent_agents)

    case ClaimStage.measure(state.claim_context, :candidate_history, fn ->
           candidate_admission(
             issue,
             state.persistence,
             state.orchestrator,
             dispatch_settings,
             "candidate_selection"
           )
         end) do
      :ok -> {:ok, workflow, issue, dispatch_settings}
      other -> other
    end
  end

  defp continue_scoped_selection({:ok, _workflow, _issue, _settings} = selected, _skip),
    do: {:halt, selected}

  defp continue_scoped_selection({:skip, _reason, _evidence} = rejected, skip),
    do: {:cont, merge_candidate_skip(skip, rejected)}

  defp continue_scoped_selection({:error, reason}, _skip), do: {:halt, {:error, reason}}

  defp revalidate_scoped(candidate, workflow, workflows, state, dispatch_settings) do
    with {:ok, %Issue{} = issue} <-
           revalidate(candidate, state, dispatch_settings),
         scope <- Config.settings!().dispatch_scope,
         {:ok, resolved_workflow, resolved_issue} <-
           DispatchScope.resolve(issue, workflows, scope),
         true <- resolved_workflow.project_id == workflow.project_id do
      {:ok, resolved_issue}
    else
      {:error, reason, rejected_issue} ->
        log_context_rejection(rejected_issue, reason)
        {:skip, reason, admission_evidence(reason, DispatchPolicy.listening_mode(dispatch_settings))}

      false ->
        reason = :issue_project_out_of_scope
        log_context_rejection(candidate, reason)
        {:skip, reason, admission_evidence(reason, DispatchPolicy.listening_mode(dispatch_settings))}

      other ->
        other
    end
  end

  defp log_context_rejection(issue, reason) do
    scope = DispatchScope.evidence(issue)["dispatch_scope"]

    Logger.warning(
      "event=admission_rejected issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
        "scope=#{inspect(scope)} context_source=#{inspect(issue.context_source)} reason=#{inspect(reason)}"
    )
  end

  defp candidate_admission(%Issue{} = issue, persistence, orchestrator, dispatch_settings, clear_source) do
    listening_mode = DispatchPolicy.listening_mode(dispatch_settings)

    with true <- DispatchPolicy.allowed_by_listening_mode?(issue.state, dispatch_settings),
         :ok <- live_issue_admission(issue, listening_mode),
         {:ok, record, runs} <- admission_history(issue, persistence),
         :ok <- check_blocking_decision(record, runs, issue, persistence, orchestrator, listening_mode, clear_source) do
      if dispatchable_from_history?(issue, runs),
        do: :ok,
        else: {:skip, :run_history, admission_evidence(:run_history, listening_mode)}
    else
      false ->
        {:skip, :listening_mode, admission_evidence(:listening_mode, listening_mode)}

      other ->
        other
    end
  end

  defp dispatchable_from_history?(%Issue{} = issue, runs) do
    if worker_started_state?(issue.state) do
      case runs do
        [%{status: status} | _] -> status in ["succeeded", "failed", "cancelled"]
        [] -> false
      end
    else
      true
    end
  end

  defp admission_history(issue, persistence) do
    case persistence.get_issue_by_identifier(issue.identifier) do
      {:error, reason} -> {:error, reason}
      record -> load_admission_runs(record, issue, persistence)
    end
  end

  defp load_admission_runs(record, issue, persistence) do
    if worker_started_state?(issue.state) or match?(%{blocking_decision: %{}}, record) do
      case persistence.list_runs_for_issue(issue.identifier, limit: 1) do
        {:error, reason} -> {:error, reason}
        runs -> {:ok, record, runs}
      end
    else
      {:ok, record, []}
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

  defp blocking_decision_admission(issue, persistence, orchestrator, listening_mode, clear_source) do
    with {:ok, record, runs} <- admission_history(issue, persistence) do
      check_blocking_decision(record, runs, issue, persistence, orchestrator, listening_mode, clear_source)
    end
  end

  defp check_blocking_decision(%{blocking_decision: %{} = decision}, runs, issue, persistence, orchestrator, listening_mode, clear_source) do
    latest_run_id =
      case runs do
        [%{id: id} | _] -> id
        [] -> nil
      end

    decision
    |> BlockingDecision.validity(issue.state, latest_run_id)
    |> apply_blocking_decision_validity(issue, decision, persistence, orchestrator, listening_mode, clear_source)
  end

  defp check_blocking_decision(_record, _runs, _issue, _persistence, _orchestrator, _listening_mode, _clear_source), do: :ok

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

  defp revalidate(%Issue{id: issue_id} = candidate, state, dispatch_settings) do
    context = Map.put(state.claim_context, :issue, candidate)

    result =
      ClaimStage.measure(context, :issue_revalidation, fn ->
        state.tracker.fetch_issue_states_by_ids([issue_id])
      end)

    case result do
      {:ok, [%Issue{} = issue | _]} ->
        revalidate_history(issue, state, dispatch_settings, context)

      {:ok, []} ->
        {:skip, :missing, admission_evidence(:missing, DispatchPolicy.listening_mode(dispatch_settings))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_history(issue, state, dispatch_settings, context) do
    result =
      ClaimStage.measure(context, :revalidation_history, fn ->
        candidate_admission(issue, state.persistence, state.orchestrator, dispatch_settings, "tracker_revalidation")
      end)

    case result do
      :ok -> {:ok, issue}
      other -> other
    end
  end

  defp prepare_assignment(state, worker, session, workflow, issue) do
    context = Map.put(state.claim_context, :issue, issue)

    ClaimStage.measure(context, :execution_admission, fn ->
      with {:ok, admission} <- state.run_admission.resolve(workflow, {:issue, issue}, %{workspace_authority: {:http_worker, worker.id, session.id}, readiness: :ready}) do
        {:ok, %{workflow: workflow, issue: issue, admission: admission, worker: worker, session: session, profile: Config.workflow_profile_for_state(issue.state)}}
      end
    end)
  end

  defp worker_started_state?(state) when is_binary(state) do
    started_states = Policy.worker_started_states() |> DispatchPolicy.normalized_state_set()
    MapSet.member?(started_states, SymphonyElixir.StateName.normalize(state))
  end

  defp worker_started_state?(_state), do: false

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
  defp expire_assignment(%{event_task: %{}} = state), do: state

  defp expire_assignment(state) do
    if DateTime.compare(state.assignment.expires_at, state.now.()) == :lt do
      assignment = Map.put_new_lazy(state.assignment, :expiry_event_id, &Ecto.UUID.generate/0)
      failure = assignment_expiry_failure(assignment)

      request = %{
        id: assignment.expiry_event_id,
        worker_id: assignment.worker_id,
        session_id: assignment.session_id,
        assignment_id: assignment.id,
        event_type: "task.failed",
        payload: %{"reason" => "assignment_expired"},
        summary: nil,
        terminal: failure
      }

      start_event_write(%{state | assignment: assignment}, request, {:ok, assignment}, nil, :expiry)
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

  defp start_reconciliation(state) do
    state = expire_assignment(state)

    if state.reconcile_task do
      state
    else
      manager = self()
      ref = make_ref()
      workflows = distinct_slug_workflows(state.workflows.list_enabled())

      {:ok, pid} =
        Task.Supervisor.start_child(state.task_supervisor, fn ->
          result = Enum.map(workflows, &reconcile_workflow_zombies(state, &1))
          GenServer.cast(manager, {:reconcile_result, ref, result})
        end)

      timer = Process.send_after(manager, {:reconcile_timeout, ref}, state.tracker_io_timeout_ms)
      %{state | reconcile_task: %{ref: ref, pid: pid, timer: timer, workflows: workflows}}
    end
  end

  defp complete_reconciliation(%{reconcile_task: task} = state, results) do
    _ = Process.cancel_timer(task.timer)

    Enum.each(results, fn
      {:error, workflow, project_slug, reason} ->
        Logger.warning("event=worker_reconcile_tracker_error project_slug=#{project_slug} reason=#{inspect(reason)}")
        record_linear_request_failure(state.persistence, workflow, "worker_reconcile", reason)

      {:ok, _project_slug} ->
        :ok
    end)

    %{state | reconcile_task: nil}
  end

  defp reconcile_workflow_zombies(state, workflow) do
    project_slug = get_in(workflow.config, ["tracker", "project_slug"])

    Config.with_workflow_context(workflow, fn ->
      fetch_and_reconcile_workflow_zombies(state, workflow, project_slug)
    end)
  end

  defp fetch_and_reconcile_workflow_zombies(state, workflow, project_slug) do
    case state.tracker.fetch_issues_by_states(["In Progress"]) do
      {:ok, issues} ->
        Enum.each(issues, &reconcile_zombie(state, &1))
        {:ok, project_slug}

      {:error, reason} ->
        {:error, workflow, project_slug, reason}
    end
  end

  defp reconcile_zombie(%{claim_task: %{operation: {:activate, %{issue: %{id: issue_id}}}}}, %Issue{id: issue_id}), do: :ok
  defp reconcile_zombie(%{claim_task: %{operation: {:abort, %{issue: %{id: issue_id}}, _reason}}}, %Issue{id: issue_id}), do: :ok

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
      record_orphan_signal(state.persistence, issue, run, started_at)
    end
  end

  defp maybe_requeue_zombie(_state, _issue, _run), do: :ok

  defp record_orphan_signal(persistence, issue, run, started_at) do
    case persistence.list_events(run_id: run.id, event_type: "run.orphaned", limit: 1) do
      [] ->
        persistence.record_event(%{
          project_id: run.project_id,
          run_id: run.id,
          issue_identifier: issue.identifier,
          event_type: "run.orphaned",
          payload: %{
            "reason" => "assignment_missing_after_lease_window",
            "started_at" => DateTime.to_iso8601(started_at),
            "operator_action" => "comment_and_move_to_todo"
          }
        })

      [_event | _rest] ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp record_linear_request_failure(persistence, workflow, operation, reason) do
    persistence.record_event(%{
      project_id: workflow.project_id,
      event_type: "linear.request_failed",
      payload:
        reason
        |> linear_failure_payload()
        |> Map.merge(%{
          "operation" => operation,
          "project_slug" => get_in(workflow.config, ["tracker", "project_slug"])
        })
    })
  end

  defp linear_failure_payload({:linear_api_status, status, _body}) when is_integer(status),
    do: %{"status" => status, "reason" => "http_status"}

  defp linear_failure_payload({:linear_api_request, reason}),
    do: %{"reason" => "transport:#{reason}"}

  defp linear_failure_payload(reason), do: %{"reason" => inspect(reason, limit: 20, printable_limit: 500)}

  defp distinct_slug_workflows(workflows),
    do: Enum.uniq_by(workflows, &get_in(&1.config, ["tracker", "project_slug"]))

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
  defp merge_candidate_skip({:skip, :listening_mode, _evidence} = current, _next), do: current
  defp merge_candidate_skip(_current, next), do: next

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
