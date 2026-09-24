# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Control do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      require Logger

      alias SymphonyElixir.{
        AgentRunner,
        BlockingDecision,
        Codex.RateLimitGate,
        Codex.Update,
        Config,
        EnvironmentFailureCircuit,
        MergeConflictReconciler,
        Nap.Results,
        Payload,
        PersistenceProvider,
        RunLifecycle,
        StatusDashboard,
        Tracker,
        WorkflowStore,
        Workspace,
        WorkspaceDiskGuard
      }

      alias SymphonyElixir.Config.Schema
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator.DispatchPolicy
      alias SymphonyElixir.Orchestrator.Events
      alias SymphonyElixir.Orchestrator.InputBlocker
      alias SymphonyElixir.Orchestrator.RetryPolicy
      alias SymphonyElixir.Orchestrator.SessionHistory
      alias SymphonyElixir.Worker.AssignmentManager

      alias SymphonyElixir.Orchestrator.{RunningIssue, RunningOperator, State}
      @spec request_refresh() :: map() | :unavailable
      def request_refresh do
        request_refresh(__MODULE__)
      end

      @spec request_refresh(GenServer.server()) :: map() | :unavailable
      def request_refresh(server) do
        if Process.whereis(server) do
          GenServer.call(server, :request_refresh)
        else
          :unavailable
        end
      end

      @spec start_listening() :: map() | :unavailable
      def start_listening do
        start_listening(__MODULE__)
      end

      @spec start_listening(GenServer.server()) :: map() | :unavailable
      def start_listening(server) do
        if Process.whereis(server) do
          GenServer.call(server, :start_listening)
        else
          :unavailable
        end
      end

      @spec start_refine_only_listening() :: map() | :unavailable
      def start_refine_only_listening do
        start_refine_only_listening(__MODULE__)
      end

      @spec start_refine_only_listening(GenServer.server()) :: map() | :unavailable
      def start_refine_only_listening(server) do
        if Process.whereis(server) do
          GenServer.call(server, :start_refine_only_listening)
        else
          :unavailable
        end
      end

      @spec stop_listening() :: map() | :unavailable
      def stop_listening do
        stop_listening(__MODULE__)
      end

      @spec stop_listening(GenServer.server()) :: map() | :unavailable
      def stop_listening(server) do
        if Process.whereis(server) do
          GenServer.call(server, :stop_listening)
        else
          :unavailable
        end
      end

      @spec reset_environment_failure_circuit() :: map() | :unavailable
      def reset_environment_failure_circuit do
        reset_environment_failure_circuit(__MODULE__)
      end

      @spec reset_environment_failure_circuit(GenServer.server()) :: map() | :unavailable
      def reset_environment_failure_circuit(server) do
        if Process.whereis(server) do
          GenServer.call(server, :reset_environment_failure_circuit)
        else
          :unavailable
        end
      end

      @spec request_nap() :: map() | :unavailable
      def request_nap do
        request_nap(nil)
      end

      @spec request_nap(String.t() | nil | GenServer.server()) :: map() | :unavailable
      def request_nap(project_id) when is_binary(project_id) or is_nil(project_id) do
        request_nap(__MODULE__, project_id)
      end

      def request_nap(server) do
        request_nap(server, nil)
      end

      @spec request_nap(GenServer.server(), String.t() | nil) :: map() | :unavailable
      def request_nap(server, project_id) do
        if GenServer.whereis(server) do
          GenServer.call(server, {:request_operator_task, :nap, project_id})
        else
          :unavailable
        end
      end

      @spec request_day_dreaming() :: map() | :unavailable
      def request_day_dreaming do
        request_day_dreaming(nil)
      end

      @spec request_day_dreaming(String.t() | nil | GenServer.server()) :: map() | :unavailable
      def request_day_dreaming(project_id) when is_binary(project_id) or is_nil(project_id) do
        request_day_dreaming(__MODULE__, project_id)
      end

      def request_day_dreaming(server) do
        request_day_dreaming(server, nil)
      end

      @spec request_day_dreaming(GenServer.server(), String.t() | nil) :: map() | :unavailable
      def request_day_dreaming(server, project_id) do
        if GenServer.whereis(server) do
          GenServer.call(server, {:request_operator_task, :day_dreaming, project_id})
        else
          :unavailable
        end
      end

      @spec force_stop_all() :: map() | :unavailable
      def force_stop_all do
        force_stop_all(__MODULE__)
      end

      @spec force_stop_all(GenServer.server()) :: map() | :unavailable
      def force_stop_all(server) do
        if GenServer.whereis(server) do
          GenServer.call(server, :force_stop_all, @control_stop_timeout_ms)
        else
          :unavailable
        end
      end

      @spec cancel_current_task() :: map() | :unavailable
      def cancel_current_task do
        cancel_current_task(nil, __MODULE__)
      end

      @spec cancel_current_task(GenServer.server() | String.t() | nil) :: map() | :unavailable
      def cancel_current_task(server) when is_atom(server) or is_pid(server) or is_tuple(server) do
        cancel_current_task(nil, server)
      end

      def cancel_current_task(project_id) when is_binary(project_id) or is_nil(project_id) do
        cancel_current_task(project_id, __MODULE__)
      end

      @spec cancel_current_task(String.t() | nil, GenServer.server()) :: map() | :unavailable
      def cancel_current_task(project_id, server) when is_binary(project_id) or is_nil(project_id) do
        if GenServer.whereis(server) do
          GenServer.call(server, {:cancel_current_task, project_id}, @control_stop_timeout_ms)
        else
          :unavailable
        end
      end

      @spec snapshot() :: map() | :timeout | :unavailable
      def snapshot do
        snapshot(__MODULE__, 15_000)
      end

      @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
      def snapshot(server, timeout) do
        if Process.whereis(server) do
          try do
            GenServer.call(server, :snapshot, timeout)
          catch
            :exit, {:timeout, _} -> :timeout
            :exit, _ -> :unavailable
          end
        else
          :unavailable
        end
      end

      @impl true
      def handle_call(:snapshot, _from, state) do
        state = refresh_runtime_config(state)
        now = DateTime.utc_now()
        now_ms = System.monotonic_time(:millisecond)

        running =
          state.running
          |> Enum.map(fn {issue_id, metadata} ->
            %{
              issue_id: Map.get(metadata, :issue_id, issue_id),
              kind: running_entry_kind(metadata),
              profile: Map.get(metadata, :profile),
              label: Map.get(metadata, :label),
              run_id: Map.get(metadata, :run_id),
              identifier: metadata.identifier,
              project_id: Map.get(metadata, :project_id),
              state: running_entry_state(metadata),
              worker_host: Map.get(metadata, :worker_host),
              workspace_path: Map.get(metadata, :workspace_path),
              session_id: metadata.session_id,
              codex_app_server_pid: metadata.codex_app_server_pid,
              codex_input_tokens: metadata.codex_input_tokens,
              codex_output_tokens: metadata.codex_output_tokens,
              codex_total_tokens: metadata.codex_total_tokens,
              turn_count: Map.get(metadata, :turn_count, 0),
              started_at: metadata.started_at,
              last_codex_timestamp: metadata.last_codex_timestamp,
              last_codex_message: metadata.last_codex_message,
              last_codex_event: metadata.last_codex_event,
              runtime_seconds: running_seconds(metadata.started_at, now),
              session_history: Map.get(metadata, :session_history, []),
              session_history_total_count:
                Map.get(
                  metadata,
                  :session_history_total_count,
                  length(Map.get(metadata, :session_history, []))
                )
            }
          end)

        retrying =
          state.retry_attempts
          |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
            %{
              issue_id: issue_id,
              attempt: attempt,
              due_in_ms: max(0, due_at_ms - now_ms),
              identifier: Map.get(retry, :identifier),
              error: Map.get(retry, :error),
              worker_host: Map.get(retry, :worker_host),
              workspace_path: Map.get(retry, :workspace_path)
            }
          end)

        blocked =
          state.blocked
          |> Enum.map(fn {_issue_id, metadata} ->
            %{
              issue_id: metadata.issue_id,
              identifier: metadata.identifier,
              state: metadata.state,
              run_id: metadata.run_id,
              worker_host: Map.get(metadata, :worker_host),
              workspace_path: Map.get(metadata, :workspace_path),
              session_id: metadata.session_id,
              reason: metadata.reason,
              detail: metadata.detail,
              blocked_at: metadata.blocked_at,
              session_history: Map.get(metadata, :session_history, []),
              session_history_total_count:
                Map.get(
                  metadata,
                  :session_history_total_count,
                  length(Map.get(metadata, :session_history, []))
                )
            }
          end)

        {:reply,
         %{
           running: running,
           retrying: retrying,
           blocked: blocked,
           codex_totals: snapshot_codex_totals(state, now),
           rate_limits: Map.get(state, :codex_rate_limits),
           rate_limit_observation: Map.get(state, :codex_rate_limit_observation),
           rate_limit_gate: rate_limit_gate_snapshot(),
           environment_failure_circuit: EnvironmentFailureCircuit.snapshot(),
           config_error: config_error_payload(state.last_config_error),
           operator_tasks: operator_tasks_payload(state),
           polling: %{
             listening?: listening?(state),
             listening_mode: listening_mode_string(state),
             checking?: state.poll_check_in_progress == true,
             next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
             poll_interval_ms: state.poll_interval_ms
           }
         }, state}
      end

      def handle_call(:request_refresh, _from, state) do
        if listening?(state) do
          do_handle_request_refresh(state)
        else
          {:reply,
           %{
             queued: false,
             coalesced: true,
             requested_at: DateTime.utc_now(),
             operations: [],
             listening?: listening?(state),
             listening_mode: listening_mode_string(state)
           }, state}
        end
      end

      def handle_call(:start_listening, _from, state) do
        case runtime_config() do
          {:ok, _config} ->
            state = %{state | listening_mode: :listening_all, last_config_error: nil}
            state = schedule_tick(state, 0)
            persist_event("orchestrator.listening_started", nil, %{mode: "listening_all"})
            notify_dashboard()

            reply = %{
              listening?: listening?(state),
              listening_mode: listening_mode_string(state),
              changed_at: DateTime.utc_now()
            }

            {:reply, reply, state}

          {:error, reason} ->
            state =
              log_config_error_once(
                %{state | listening_mode: :not_listening, poll_check_in_progress: false},
                reason
              )

            notify_dashboard()

            reply = %{
              listening?: listening?(state),
              listening_mode: listening_mode_string(state),
              error: inspect(reason),
              changed_at: DateTime.utc_now()
            }

            {:reply, reply, state}
        end
      end

      def handle_call(:start_refine_only_listening, _from, state) do
        case runtime_config() do
          {:ok, _config} ->
            state = %{state | listening_mode: :listening_refine_only, last_config_error: nil}
            state = schedule_tick(state, 0)
            persist_event("orchestrator.listening_started", nil, %{mode: "listening_refine_only"})
            notify_dashboard()

            reply = %{
              listening?: listening?(state),
              listening_mode: listening_mode_string(state),
              changed_at: DateTime.utc_now()
            }

            {:reply, reply, state}

          {:error, reason} ->
            state =
              log_config_error_once(
                %{state | listening_mode: :not_listening, poll_check_in_progress: false},
                reason
              )

            notify_dashboard()

            reply = %{
              listening?: listening?(state),
              listening_mode: listening_mode_string(state),
              error: inspect(reason),
              changed_at: DateTime.utc_now()
            }

            {:reply, reply, state}
        end
      end

      def handle_call(:stop_listening, _from, state) do
        previous_mode = listening_mode_string(state)
        state = %{state | listening_mode: :not_listening, poll_check_in_progress: false}
        persist_event("orchestrator.listening_stopped", nil, %{previous_mode: previous_mode})
        notify_dashboard()

        reply = %{
          listening?: listening?(state),
          listening_mode: listening_mode_string(state),
          changed_at: DateTime.utc_now()
        }

        {:reply, reply, state}
      end

      def handle_call({:worker_claim, worker_id, session_id, attrs, assignment_manager}, _from, state) do
        result =
          case listening_mode_atom(state) do
            :not_listening ->
              AssignmentManager.reject_claim(worker_id, session_id, :not_listening)

            listening_mode ->
              AssignmentManager.claim_with_policy_evidence(
                worker_id,
                session_id,
                attrs,
                listening_mode,
                state.max_concurrent_agents,
                assignment_manager
              )
          end

        {:reply, result, state}
      end

      def handle_call(:reset_environment_failure_circuit, _from, state) do
        circuit = EnvironmentFailureCircuit.reset()
        persist_event("environment_failure_circuit.reset", nil, %{status: :allow})
        notify_dashboard()
        {:reply, %{environment_failure_circuit: circuit, reset_at: DateTime.utc_now()}, state}
      end

      def handle_call(:force_stop_all, _from, state) do
        {state, rollback_results} =
          state
          |> Map.put(:listening_mode, :not_listening)
          |> clear_operator_tasks(:stopped)
          |> cancel_retry_timers()
          |> force_stop_running_entries()

        cancelled_tasks = cancel_active_worker_tasks()

        persist_event("orchestrator.force_stop_all", nil, %{
          rollback_results: rollback_results,
          cancelled_tasks: cancelled_tasks
        })

        notify_dashboard()

        {:reply,
         %{
           listening?: listening?(state),
           listening_mode: listening_mode_string(state),
           stopped_agents: length(rollback_results),
           cancelled_tasks: cancelled_tasks,
           rollback_results: rollback_results,
           changed_at: DateTime.utc_now()
         }, state}
      end

      def handle_call({:cancel_current_task, project_id}, _from, state) do
        cancelled_tasks = AssignmentManager.cancel_current("cancel_current", project_id)

        {:reply,
         %{
           listening?: listening?(state),
           listening_mode: listening_mode_string(state),
           cancelled_tasks: cancelled_tasks,
           changed_at: DateTime.utc_now()
         }, state}
      end

      def handle_call({:request_operator_task, kind}, _from, state)
          when kind in [:nap, :day_dreaming] do
        handle_operator_task_request(state, kind, nil)
      end

      def handle_call({:request_operator_task, kind, project_id}, _from, state)
          when kind in [:nap, :day_dreaming] do
        handle_operator_task_request(state, kind, project_id)
      end

      defp handle_operator_task_request(state, kind, project_id) do
        {state, task, request_status} = request_operator_task(state, kind, project_id)

        if request_status == :accepted do
          persist_event("operator_task.requested", nil, %{
            kind: to_string(kind),
            project_id: task.project_id,
            status: task.status,
            run_id: task.run_id
          })

          notify_dashboard()
        end

        {:reply, operator_task_reply(task, request_status), state}
      end

      defp do_handle_request_refresh(state) do
        now_ms = System.monotonic_time(:millisecond)
        already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
        coalesced = state.poll_check_in_progress == true or already_due?

        state =
          if coalesced do
            state
          else
            schedule_tick(state, 0)
          end

        {:reply,
         %{
           queued: true,
           coalesced: coalesced,
           requested_at: DateTime.utc_now(),
           operations: ["poll", "reconcile"],
           listening?: listening?(state),
           listening_mode: listening_mode_string(state)
         }, state}
      end

      defp request_operator_task(%State{} = state, kind, project_id) do
        state = reconcile_stale_operator_entries(state)
        current = operator_task(state, kind)

        case current.status do
          :queued ->
            reject_operator_task(state, current, project_id, {:operator_task_already_queued, kind})

          status when status in [:starting, :running] ->
            reject_operator_task(state, current, project_id, {:operator_task_busy, kind})

          _ ->
            {state, task} = request_new_operator_task(state, kind, project_id)
            {state, task, :accepted}
        end
      end

      defp reject_operator_task(state, current, project_id, reason) do
        failure_reason = operator_task_rejection_reason(reason)

        Logger.error(
          "Operator task request rejected action=reject kind=#{current.kind} project_id=#{project_id || "n/a"} " <>
            "active_project_id=#{current.project_id || "n/a"} run_id=#{current.run_id || "n/a"} reason=#{inspect(reason)}"
        )

        rejected = %{
          current
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: failure_reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
        }

        {state, rejected, :rejected}
      end

      defp operator_task_rejection_reason({:operator_task_busy, kind}) do
        "operator_task_busy: #{kind} run is already in progress"
      end

      defp operator_task_rejection_reason({:operator_task_already_queued, kind}) do
        "operator_task_already_queued: #{kind} run is already queued"
      end

      defp request_new_operator_task(state, kind, project_id) do
        case resolve_operator_project(project_id) do
          {:ok, project} ->
            request_operator_task_for_project(state, kind, project)

          {:error, reason} ->
            put_failed_operator_task(state, kind, new_operator_task(kind, project_id), reason)
        end
      end

      defp request_operator_task_for_project(state, kind, project) do
        task = new_operator_task(kind, Map.fetch!(project, :id))

        case load_operator_workflow(project) do
          {:ok, workflow} ->
            Config.with_workflow_context(workflow, fn ->
              queue_or_start_operator_task(state, kind, task)
            end)

          {:error, reason} ->
            put_failed_operator_task(state, kind, task, reason)
        end
      end

      defp queue_or_start_operator_task(state, kind, task) do
        if runtime_busy?(state) or rate_limit_gate_blocked?(state) do
          queued = %{task | status: :queued, queued_at: DateTime.utc_now()}
          {put_operator_task(state, kind, queued), queued}
        else
          {state, started} = start_operator_task(state, task)
          {put_operator_task(state, kind, started), started}
        end
      end

      defp put_failed_operator_task(state, kind, task, reason) do
        failed = fail_operator_task_resolution(task, reason)
        {put_operator_task(state, kind, failed), failed}
      end

      defp maybe_start_queued_operator_tasks(%State{} = state) do
        state = reconcile_stale_operator_entries(state)

        if runtime_busy?(state) do
          state
        else
          Enum.reduce([:nap, :day_dreaming], state, &maybe_start_queued_operator_task/2)
        end
      end

      defp maybe_start_queued_operator_task(kind, state) do
        task = operator_task(state, kind)

        if task.status == :queued do
          {state, started} = start_operator_task(state, task)

          if started.status == :running do
            persist_event("operator_task.started", nil, %{
              kind: to_string(kind),
              run_id: started.run_id
            })
          end

          put_operator_task(state, kind, started)
        else
          state
        end
      end

      defp new_operator_task(kind, project_id) do
        %{
          kind: kind,
          project_id: project_id,
          status: :idle,
          run_id: "operator-#{kind}-#{System.unique_integer([:positive])}",
          requested_at: DateTime.utc_now(),
          queued_at: nil,
          started_at: nil,
          finished_at: nil,
          failure_reason: nil,
          summary: nil
        }
      end

      defp start_operator_task(%State{} = state, task) do
        with {:ok, project} <- resolve_operator_project(task.project_id),
             {:ok, workflow} <- load_operator_workflow(project) do
          Config.with_workflow_context(workflow, fn ->
            maybe_start_operator_task_for_workflow(state, task, workflow)
          end)
        else
          {:error, reason} -> {state, fail_operator_task_resolution(task, reason)}
        end
      end

      defp maybe_start_operator_task_for_workflow(state, task, workflow) do
        if rate_limit_gate_blocked?(state) do
          {state, task}
        else
          do_start_operator_task(state, task, workflow)
        end
      end

      defp do_start_operator_task(%State{} = state, task, workflow) do
        started = %{
          task
          | status: :running,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            failure_reason: nil,
            summary: %{created: 0, skipped: 0, failed: 0, issues: []}
        }

        case persist_operator_run_started(started) do
          {:ok, run} ->
            start_operator_task_after_run(state, started, run, workflow)

          {:error, reason} ->
            failure_reason =
              "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1000)}"

            Logger.error("Operator run-start persistence failed action=fail_task kind=#{task.kind} run_id=#{task.run_id} reason=#{inspect(reason, limit: 20, printable_limit: 1000)}")

            failed = %{
              started
              | status: :failed,
                finished_at: DateTime.utc_now(),
                failure_reason: failure_reason,
                summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
            }

            {state, failed}
        end
      end

      defp spawn_operator_task(%State{} = state, task, worker_host, workflow) do
        recipient = self()

        case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               run_operator_task(state, task, recipient, worker_host, workflow)
             end) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            Logger.info("Dispatching operator task to agent: kind=#{task.kind} run_id=#{task.run_id} pid=#{inspect(pid)} worker_host=#{worker_host || "local"}")

            {put_operator_running_entry(state, task, pid, ref, worker_host), task}

          {:error, reason} ->
            fail_operator_task_start(state, task, "failed to spawn operator task: #{inspect(reason)}")
        end
      end

      defp run_operator_task(state, task, recipient, worker_host, workflow) do
        Config.with_workflow_context(workflow, fn ->
          result =
            agent_runner().run_operator(task.kind, task.run_id, recipient,
              project_id: task.project_id,
              worker_host: worker_host,
              run_id: task.run_id,
              rate_limit_snapshot: state.codex_rate_limits,
              rate_limit_settings: Config.settings!()
            )

          send(recipient, {:agent_runner_finished, task.run_id, result})
          result
        end)
      end

      defp fail_operator_task_start(%State{} = state, task, reason) do
        failed = %{
          task
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: reason}
        }

        running_entry = operator_running_entry(failed, nil, nil, "local")

        persist_event(
          "operator_task.failed",
          nil,
          %{kind: to_string(task.kind), run_id: task.run_id, reason: reason},
          task.run_id
        )

        persist_run_finished(running_entry, "failed", reason)

        {state, failed}
      end

      defp put_operator_running_entry(%State{} = state, task, pid, ref, worker_host) do
        running_entry = operator_running_entry(task, pid, ref, worker_host)
        %{state | running: Map.put(state.running, task.run_id, running_entry)}
      end

      defp operator_running_entry(task, pid, ref, worker_host) do
        identity = AgentRunner.operator_task_identity(task.kind, task.run_id)

        running_entry = %RunningOperator{
          kind: task.kind,
          profile: to_string(task.kind),
          label: identity.label,
          project_id: task.project_id,
          pid: pid,
          ref: ref,
          run_id: task.run_id,
          identifier: identity.identifier,
          issue_id: nil,
          issue: nil,
          state: to_string(task.status),
          worker_host: worker_host,
          workspace_path: nil,
          session_id: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: "operator_task.started",
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0,
          retry_attempt: 0,
          started_at: task.started_at,
          session_history: [
            %{
              at: task.started_at,
              source: :system,
              event: "operator_task.started",
              label: identity.label,
              detail: "Operator task started",
              severity: :info
            }
          ],
          session_history_total_count: 1
        }

        running_entry
      end

      defp operator_task_issue(task) do
        identity = AgentRunner.operator_task_identity(task.kind, task.run_id)

        %Issue{
          id: task.run_id,
          identifier: identity.identifier,
          title: identity.label,
          description: identity.description,
          state: identity.label,
          assigned_to_worker: false,
          labels: ["operator", to_string(task.kind)]
        }
      end

      defp operator_task_label(kind) do
        AgentRunner.operator_task_identity(kind, nil).label
      end

      defp finish_operator_task(%State{} = state, running_entry, status, failure_reason)
           when status in [:completed, :failed] do
        case operator_kind_from_running_entry(running_entry) do
          nil ->
            state

          kind ->
            now = DateTime.utc_now()

            task =
              state
              |> operator_task(kind)
              |> Map.merge(%{
                status: status,
                run_id: Map.get(running_entry, :run_id),
                finished_at: now,
                failure_reason: failure_reason,
                summary: operator_task_summary(status, failure_reason, Map.get(running_entry, :run_id))
              })

            put_operator_task(state, kind, task)
        end
      end

      defp operator_task_summary(:completed, _failure_reason, run_id) do
        operator_task_results(run_id)
      end

      defp operator_task_summary(:failed, failure_reason, run_id) do
        run_id
        |> operator_task_results()
        |> Map.update!(:failed, &max(&1, 1))
        |> Map.put(:error, failure_reason)
      end

      defp operator_task_results(run_id) when is_binary(run_id) do
        case PersistenceProvider.read(fn ->
               persistence().list_events(
                 run_id: run_id,
                 event_type: "linear.tool_call",
                 order: :asc,
                 limit: 10_000
               )
             end) do
          events when is_list(events) ->
            Results.aggregate(events)

          {:error, reason} ->
            Results.aggregate([])
            |> Map.merge(%{unavailable: true, error: inspect(reason)})
        end
      end

      defp operator_task_results(_run_id) do
        Results.aggregate([])
      end

      defp resolve_operator_project(nil) do
        resolve_unambiguous_operator_project()
      end

      defp resolve_operator_project("") do
        resolve_unambiguous_operator_project()
      end

      defp resolve_operator_project(project_id) when is_binary(project_id) do
        case enabled_operator_projects() do
          {:ok, projects} ->
            case Enum.find(projects, &(Map.get(&1, :id) == project_id)) do
              nil -> {:error, :unknown_project}
              project -> {:ok, project}
            end

          {:error, reason} ->
            {:error, {:project_lookup_failed, reason}}
        end
      end

      defp resolve_unambiguous_operator_project do
        case enabled_operator_projects() do
          {:ok, [project]} -> {:ok, project}
          {:ok, _projects} -> {:error, :project_required}
          {:error, reason} -> {:error, {:project_lookup_failed, reason}}
        end
      end

      defp enabled_operator_projects do
        case PersistenceProvider.read(fn -> persistence().list_projects() end) do
          projects when is_list(projects) ->
            {:ok, Enum.filter(projects, &(Map.get(&1, :enabled, true) == true))}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_list_projects_result, other}}
        end
      end
    end
  end
end
