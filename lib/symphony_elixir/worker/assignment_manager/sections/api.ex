# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Worker.AssignmentManager.Sections.Api do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
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
      alias SymphonyElixir.Linear.Issue
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

        ClaimStage.measure(state.claim_context, :workflows, fn -> state.workflows.list_enabled() end)
        |> distinct_slug_workflows()
        |> Enum.reduce_while(empty, fn workflow, {:ok, nil, evidence} ->
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
      defp tracker_backoff_error?({:claim_prepare_timeout, _stage}), do: true
      defp tracker_backoff_error?({:claim_prepare_failed, _stage, _reason}), do: true
      defp tracker_backoff_error?(_reason), do: false

      defp claim_from_workflow(state, worker, session, workflow, dispatch_settings) do
        with {:ok, candidates} <-
               ClaimStage.measure(state.claim_context, :candidate_fetch, fn ->
                 state.tracker.fetch_candidate_issues()
               end),
             {:ok, %Issue{} = candidate} <-
               ClaimStage.measure(state.claim_context, :candidate_history, fn ->
                 select_candidate(candidates, state.persistence, state.orchestrator, dispatch_settings)
               end),
             {:ok, %Issue{} = issue} <-
               revalidate(candidate, state, dispatch_settings),
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
    end
  end
end
