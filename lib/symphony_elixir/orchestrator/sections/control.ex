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
        RunAdmission,
        RunFailure,
        RunLifecycle,
        StatusDashboard,
        Tracker,
        WorkflowStore,
        Workspace,
        WorkspacePreflight
      }

      alias SymphonyElixir.Config.Schema
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator.DispatchPolicy
      alias SymphonyElixir.Orchestrator.Events
      alias SymphonyElixir.Orchestrator.InputBlocker
      alias SymphonyElixir.Orchestrator.RetryPolicy
      alias SymphonyElixir.Orchestrator.{RunningIssue, RunningOperator, State}
      alias SymphonyElixir.Orchestrator.SessionHistory
      alias SymphonyElixir.Worker.AssignmentManager, as: AM
      alias SymphonyElixir.Workspace.{Remote, SourcePreparation}

      defp parse_ssh_workspace_preflight(output, root, min_free_bytes) do
        marker =
          output
          |> IO.iodata_to_binary()
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case String.split(line, "\t") do
              ["__SYMPHONY_PREFLIGHT__" | fields] -> fields
              _ -> nil
            end
          end)

        case marker do
          ["ok"] ->
            :ok

          ["not_creatable"] ->
            {:error, %{kind: :not_creatable, path: root, reason: :write_probe_failed}}

          ["not_writable"] ->
            {:error, %{kind: :not_writable, path: root, reason: :write_probe_failed}}

          ["disk_space_unavailable"] ->
            {:error, %{kind: :disk_space_unavailable, path: root, reason: :df_failed}}

          ["low_disk_space", free_bytes] ->
            {:error,
             %{
               kind: :low_disk_space,
               path: root,
               reason: %{free_bytes: String.to_integer(free_bytes), min_free_bytes: min_free_bytes}
             }}
        end
      end

      defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
        Enum.find(issues, fn
          %Issue{id: ^issue_id} ->
            true

          _ ->
            false
        end)
      end

      defp find_issue_id_for_ref(running, ref) do
        running
        |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
          if running_ref == ref, do: issue_id
        end)
      end

      defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
        do: session_id

      defp running_entry_session_id(_running_entry), do: "n/a"

      defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
        "issue_id=#{issue_id} issue_identifier=#{identifier}"
      end

      defp available_slots(%State{} = state) do
        max(state.max_concurrent_agents - map_size(state.running), 0)
      end

      defp refresh_deployment_capacity(%State{} = state) do
        capacity =
          case RunAdmission.execution_mode() do
            "worker" -> worker_deployment_capacity(state.worker_capacity_query)
            "centralized" -> Config.panel_max_concurrent_agents()
          end

        %{state | max_concurrent_agents: capacity}
      end

      defp worker_deployment_capacity(worker_capacity_query) do
        worker_capacity_query.()
      catch
        :exit, {:timeout, {GenServer, :call, [AM, :available_worker_slots, @capacity_query_timeout_ms]}} ->
          Logger.warning("event=orchestrator.capacity_query_timeout execution_mode=worker timeout_ms=5000 fallback_capacity=0")

          0
      end

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
      def start_listening, do: start_listening(__MODULE__)

      @spec start_listening(GenServer.server()) :: map() | :unavailable
      def start_listening(server) do
        if Process.whereis(server), do: GenServer.call(server, :start_listening), else: :unavailable
      end

      @spec start_refine_only_listening() :: map() | :unavailable
      def start_refine_only_listening, do: start_refine_only_listening(__MODULE__)

      @spec start_refine_only_listening(GenServer.server()) :: map() | :unavailable
      def start_refine_only_listening(server) do
        if Process.whereis(server),
          do: GenServer.call(server, :start_refine_only_listening),
          else: :unavailable
      end

      @spec stop_listening() :: map() | :unavailable
      def stop_listening, do: stop_listening(__MODULE__)

      @spec stop_listening(GenServer.server()) :: map() | :unavailable
      def stop_listening(server) do
        if Process.whereis(server), do: GenServer.call(server, :stop_listening), else: :unavailable
      end

      @spec reset_environment_failure_circuit() :: map() | :unavailable
      def reset_environment_failure_circuit, do: reset_environment_failure_circuit(__MODULE__)

      @spec reset_environment_failure_circuit(GenServer.server()) :: map() | :unavailable
      def reset_environment_failure_circuit(server) do
        if Process.whereis(server),
          do: GenServer.call(server, :reset_environment_failure_circuit),
          else: :unavailable
      end

      @spec request_nap() :: map() | :unavailable
      def request_nap, do: request_nap(nil)

      @spec request_nap(String.t() | nil | GenServer.server()) :: map() | :unavailable
      def request_nap(project_id) when is_binary(project_id) or is_nil(project_id),
        do: request_nap(__MODULE__, project_id)

      def request_nap(server), do: request_nap(server, nil)

      @spec request_nap(GenServer.server(), String.t() | nil) :: map() | :unavailable
      def request_nap(server, project_id) do
        if GenServer.whereis(server),
          do: GenServer.call(server, {:request_operator_task, :nap, project_id}),
          else: :unavailable
      end

      @spec request_day_dreaming() :: map() | :unavailable
      def request_day_dreaming, do: request_day_dreaming(nil)

      @spec request_day_dreaming(String.t() | nil | GenServer.server()) :: map() | :unavailable
      def request_day_dreaming(project_id) when is_binary(project_id) or is_nil(project_id),
        do: request_day_dreaming(__MODULE__, project_id)

      def request_day_dreaming(server), do: request_day_dreaming(server, nil)

      @spec request_day_dreaming(GenServer.server(), String.t() | nil) :: map() | :unavailable
      def request_day_dreaming(server, project_id) do
        if GenServer.whereis(server),
          do: GenServer.call(server, {:request_operator_task, :day_dreaming, project_id}),
          else: :unavailable
      end

      @spec force_stop_all() :: map() | :unavailable
      def force_stop_all, do: force_stop_all(__MODULE__)

      @spec force_stop_all(GenServer.server()) :: map() | :unavailable
      def force_stop_all(server) do
        if GenServer.whereis(server),
          do: GenServer.call(server, :force_stop_all, @control_stop_timeout_ms),
          else: :unavailable
      end

      @spec cancel_current_task() :: map() | :unavailable
      def cancel_current_task, do: cancel_current_task(nil, __MODULE__)

      @spec cancel_current_task(GenServer.server() | String.t() | nil) :: map() | :unavailable
      def cancel_current_task(server) when is_atom(server) or is_pid(server) or is_tuple(server) do
        cancel_current_task(nil, server)
      end

      def cancel_current_task(project_id) when is_binary(project_id) or is_nil(project_id) do
        cancel_current_task(project_id, __MODULE__)
      end

      @spec cancel_current_task(String.t() | nil, GenServer.server()) :: map() | :unavailable
      def cancel_current_task(project_id, server) when is_binary(project_id) or is_nil(project_id) do
        if GenServer.whereis(server),
          do: GenServer.call(server, {:cancel_current_task, project_id}, @control_stop_timeout_ms),
          else: :unavailable
      end

      @spec snapshot() :: map() | :timeout | :unavailable
      def snapshot, do: snapshot(__MODULE__, 15_000)

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
        handle_start_listening(state, :listening_all)
      end

      def handle_call(:start_refine_only_listening, _from, state) do
        handle_start_listening(state, :listening_refine_only)
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
              AM.reject_claim(worker_id, session_id, :not_listening)

            listening_mode ->
              AM.claim_with_policy_evidence(
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
        cancelled_tasks = AM.cancel_current("cancel_current", project_id)

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

      defp handle_start_listening(state, mode) do
        with {:ok, _config} <- runtime_config(),
             :ok <- preflight_listening_workspace() do
          state = %{state | listening_mode: mode, last_config_error: nil}
          state = schedule_tick(state, 0)
          persist_event("orchestrator.listening_started", nil, %{mode: Atom.to_string(mode)})
          notify_dashboard()

          reply = %{
            listening?: listening?(state),
            listening_mode: listening_mode_string(state),
            changed_at: DateTime.utc_now()
          }

          {:reply, reply, state}
        else
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
              error: listening_error(reason),
              changed_at: DateTime.utc_now()
            }

            {:reply, reply, state}
        end
      end

      defp preflight_listening_workspace do
        case WorkflowStore.list_enabled() do
          [workflow | _workflows] ->
            Config.with_workflow_context(workflow, &preflight_current_workspace/0)

          [] ->
            preflight_current_workspace()
        end
      end

      defp preflight_current_workspace do
        with {:ok, settings} <- Config.settings() do
          WorkspacePreflight.check(:pre_listen, settings: settings)
        end
      end

      defp listening_error(%{kind: _kind} = rejection), do: rejection
      defp listening_error(reason), do: inspect(reason)

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
        state = if coalesced, do: state, else: schedule_tick(state, 0)

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
            request_status = if task.status == :failed, do: :rejected, else: :accepted
            {state, task, request_status}
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

      defp operator_task_rejection_reason({:operator_task_busy, kind}),
        do: "operator_task_busy: #{kind} run is already in progress"

      defp operator_task_rejection_reason({:operator_task_already_queued, kind}),
        do: "operator_task_already_queued: #{kind} run is already queued"

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
              request_operator_task_in_mode(state, kind, task, RunAdmission.execution_mode())
            end)

          {:error, reason} ->
            put_failed_operator_task(state, kind, task, reason)
        end
      end

      defp request_operator_task_in_mode(state, kind, task, "worker") do
        {state, failed} =
          fail_operator_admission(state, task, %{
            kind: :execution_mode_unavailable,
            execution_mode: "worker",
            surface: :centralized
          })

        {put_operator_task(state, kind, failed), failed}
      end

      defp request_operator_task_in_mode(state, kind, task, "centralized") do
        queue_or_start_operator_task(state, kind, task)
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
        if rate_limit_gate_blocked?(state),
          do: {state, task},
          else: do_start_operator_task(state, task, workflow)
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

        start_operator_task_with_admission(state, started, workflow)
      end

      defp start_operator_task_with_admission(state, started, workflow) do
        if RunAdmission.execution_mode() == "worker" do
          fail_operator_admission(state, started, %{
            kind: :execution_mode_unavailable,
            execution_mode: "worker",
            surface: :centralized
          })
        else
          admit_centralized_operator_task(state, started, workflow)
        end
      end

      defp admit_centralized_operator_task(state, started, workflow) do
        case select_worker_host(state, nil) do
          :no_worker_capacity ->
            fail_operator_admission(state, started, %{kind: :no_worker_capacity, surface: :centralized})

          worker_host ->
            case RunAdmission.resolve(
                   workflow,
                   {:operator, started},
                   centralized_execution_context(worker_host)
                 ) do
              {:ok, admission} ->
                persist_admitted_operator_task(state, started, workflow, worker_host, admission)

              {:error, {:environment_unavailable, evidence}} ->
                fail_operator_admission(state, started, evidence)
            end
        end
      end

      defp persist_admitted_operator_task(state, started, workflow, worker_host, admission) do
        case persist_operator_run_started(started, admission) do
          {:ok, run} ->
            start_operator_task_after_run(state, started, run, workflow, worker_host, admission)

          {:error, reason} ->
            failure_reason =
              "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"

            Logger.error("Operator run-start persistence failed action=fail_task kind=#{started.kind} run_id=#{started.run_id} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")

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

      defp fail_operator_admission(state, task, evidence) do
        reason = "environment_unavailable: #{inspect(evidence)}"

        failed = %{
          task
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: reason}
        }

        {state, failed}
      end

      defp spawn_operator_task(%State{} = state, task, worker_host, workflow, admission) do
        recipient = self()

        case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               run_operator_task(state, task, recipient, worker_host, workflow, admission)
             end) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            Logger.info("Dispatching operator task to agent: kind=#{task.kind} run_id=#{task.run_id} pid=#{inspect(pid)} worker_host=#{worker_host || "local"}")

            {put_operator_running_entry(state, task, pid, ref, worker_host, admission), task}

          {:error, reason} ->
            fail_operator_task_start(
              state,
              task,
              "failed to spawn operator task: #{inspect(reason)}",
              admission
            )
        end
      end

      defp run_operator_task(state, task, recipient, worker_host, workflow, admission) do
        Config.with_workflow_context(workflow, fn ->
          result =
            agent_runner().run_operator(task.kind, task.run_id, recipient,
              project_id: task.project_id,
              worker_host: worker_host,
              run_id: task.run_id,
              admission: admission,
              max_turns: admission.limits.max_turns,
              rate_limit_snapshot: state.codex_rate_limits,
              rate_limit_settings: Config.settings!()
            )

          send(recipient, {:agent_runner_finished, task.run_id, result})
          result
        end)
      end

      defp fail_operator_task_start(%State{} = state, task, reason, admission) do
        failed = %{
          task
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: reason}
        }

        running_entry = operator_running_entry(failed, nil, nil, "local", admission)
        run_kind = running_entry_kind(running_entry)

        persist_event(
          "operator_task.failed",
          nil,
          %{kind: to_string(task.kind), run_id: task.run_id, reason: reason},
          task.run_id
        )

        failure =
          RunFailure.classify({:operator_domain_failure, %{reason: reason, action: "start", run_kind: run_kind}})

        persist_run_finished(running_entry, "failed", failure)

        {state, failed}
      end

      defp put_operator_running_entry(%State{} = state, task, pid, ref, worker_host, admission) do
        running_entry = operator_running_entry(task, pid, ref, worker_host, admission)
        %{state | running: Map.put(state.running, task.run_id, running_entry)}
      end

      defp operator_running_entry(task, pid, ref, worker_host, admission) do
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
          admission: admission,
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

      defp operator_task_label(kind), do: AgentRunner.operator_task_identity(kind, nil).label
    end
  end
end
