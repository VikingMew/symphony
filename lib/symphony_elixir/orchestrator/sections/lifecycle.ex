# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Lifecycle do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Orchestrator.{RunningIssue, RunningOperator, State}
      use GenServer
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

      @retry_due_at_display_grace_ms 400
      @poll_transition_render_delay_ms 20
      @mergeability_checks_per_poll 20
      @control_stop_timeout_ms 35_000
      @capacity_query_timeout_ms 5000
      @capacity_query_args [
        AssignmentManager,
        :available_worker_slots,
        @capacity_query_timeout_ms
      ]
      @empty_codex_totals %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0
      }

      defmodule RunningIssue do
        @moduledoc false

        defstruct [
          :pid,
          :ref,
          :run_id,
          :identifier,
          :issue,
          :project_id,
          :worker_host,
          :workspace_path,
          :session_id,
          :last_codex_message,
          :last_codex_timestamp,
          :last_codex_event,
          :codex_app_server_pid,
          :started_at,
          :agent_result,
          kind: :issue,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0,
          retry_attempt: 0,
          failure_count: 0,
          session_history: [],
          session_history_total_count: 0,
          linear_state_transitions: [],
          implementation_handoff_completed: false
        ]

        @type t :: %__MODULE__{}
      end

      defmodule RunningOperator do
        @moduledoc false

        defstruct [
          :kind,
          :profile,
          :label,
          :pid,
          :ref,
          :run_id,
          :identifier,
          :issue_id,
          :issue,
          :project_id,
          :state,
          :worker_host,
          :workspace_path,
          :session_id,
          :last_codex_message,
          :last_codex_timestamp,
          :last_codex_event,
          :codex_app_server_pid,
          :started_at,
          :agent_result,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0,
          retry_attempt: 0,
          session_history: [],
          session_history_total_count: 0
        ]

        @type t :: %__MODULE__{}
      end

      defmodule State do
        @moduledoc "Runtime state for the orchestrator polling loop.\n"

        defstruct [
          :poll_interval_ms,
          :max_concurrent_agents,
          :next_poll_due_at_ms,
          :poll_check_in_progress,
          :tick_timer_ref,
          :tick_token,
          running: %{},
          blocked: %{},
          completed: MapSet.new(),
          claimed: MapSet.new(),
          retry_attempts: %{},
          failure_counts: %{},
          codex_totals: nil,
          codex_rate_limits: nil,
          codex_rate_limit_observation: nil,
          rate_limit_gate: nil,
          rate_limit_gate_event_fingerprint: nil,
          last_config_error: nil,
          listening_mode: :not_listening,
          operator_tasks: %{}
        ]

        @type t :: %__MODULE__{}
      end

      @type worker_terminal_outcome ::
              :success | :cancelled | {:blocked, term()} | {:failed, term()}
      @type listening_mode :: :not_listening | :listening_all | :listening_refine_only

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @spec claim_worker(String.t(), String.t(), map(), GenServer.server(), GenServer.server()) ::
              {:ok, map() | {:empty, pos_integer()}, map()}
              | {:error, term()}
              | {:error, term(), pos_integer()}
      def claim_worker(
            worker_id,
            session_id,
            attrs,
            server \\ __MODULE__,
            assignment_manager \\ AssignmentManager
          ) do
        GenServer.call(
          server,
          {:worker_claim, worker_id, session_id, attrs, assignment_manager},
          :infinity
        )
      end

      @spec worker_task_started(map(), GenServer.server()) :: :ok
      def worker_task_started(%{issue: %Issue{id: issue_id}} = assignment, server \\ __MODULE__)
          when is_binary(issue_id) do
        GenServer.cast(server, {:worker_task_started, assignment})
      end

      @spec worker_task_progress(String.t(), map(), GenServer.server()) :: :ok
      def worker_task_progress(issue_id, payload, server \\ __MODULE__)
          when is_binary(issue_id) and is_map(payload) do
        GenServer.cast(server, {:worker_task_progress, issue_id, payload})
      end

      @spec worker_task_finished(String.t(), worker_terminal_outcome(), GenServer.server()) :: :ok
      def worker_task_finished(issue_id, outcome, server \\ __MODULE__) when is_binary(issue_id) do
        GenServer.cast(server, {:worker_task_finished, issue_id, outcome})
      end

      @impl true
      def init(_opts) do
        now_ms = System.monotonic_time(:millisecond)

        state =
          case runtime_config() do
            {:ok, config} ->
              run_terminal_workspace_cleanup()
              RunLifecycle.close_stale_running_runs(persistence())

              %State{
                poll_interval_ms: config.polling.interval_ms,
                max_concurrent_agents: Config.panel_max_concurrent_agents(),
                next_poll_due_at_ms: now_ms,
                poll_check_in_progress: false,
                tick_timer_ref: nil,
                tick_token: nil,
                codex_totals: @empty_codex_totals,
                codex_rate_limits: nil,
                codex_rate_limit_observation: nil
              }
              |> restore_persistent_blocked()
              |> schedule_tick(config.polling.interval_ms)

            {:error, reason} ->
              Logger.error("Orchestrator started with invalid runtime configuration; listening is disabled: #{config_validation_error_message(reason)}")

              %State{
                poll_interval_ms: 30_000,
                max_concurrent_agents: 0,
                next_poll_due_at_ms: now_ms,
                poll_check_in_progress: false,
                tick_timer_ref: nil,
                tick_token: nil,
                codex_totals: @empty_codex_totals,
                codex_rate_limits: nil,
                codex_rate_limit_observation: nil,
                last_config_error: reason
              }
              |> schedule_tick(30_000)
          end

        {:ok, state}
      end

      @impl true
      def handle_cast({:worker_task_started, %{issue: %Issue{id: issue_id}} = assignment}, state)
          when is_binary(issue_id) do
        state = handle_worker_task_started(state, assignment)
        notify_dashboard()
        {:noreply, state}
      end

      def handle_cast({:worker_task_progress, issue_id, payload}, state)
          when is_binary(issue_id) and is_map(payload) do
        {:noreply, handle_worker_task_progress(state, issue_id, payload)}
      end

      def handle_cast({:worker_task_finished, issue_id, outcome}, state) when is_binary(issue_id) do
        {:noreply, handle_worker_task_finished(state, issue_id, outcome)}
      end

      @impl true
      def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
          when is_reference(tick_token) do
        state = refresh_runtime_config(state)

        state = %{
          state
          | poll_check_in_progress: true,
            next_poll_due_at_ms: nil,
            tick_timer_ref: nil,
            tick_token: nil
        }

        notify_dashboard()
        :ok = schedule_poll_cycle_start()
        {:noreply, state}
      end

      def handle_info({:tick, _tick_token}, state) do
        {:noreply, state}
      end

      def handle_info(:run_poll_cycle, state) do
        state = refresh_runtime_config(state)

        state =
          if listening?(state) do
            maybe_dispatch(state)
          else
            state
          end

        state = schedule_tick(state, state.poll_interval_ms)
        state = %{state | poll_check_in_progress: false}

        notify_dashboard()
        {:noreply, state}
      end

      def handle_info(
            {:DOWN, ref, :process, _pid, reason},
            %{running: running} = state
          ) do
        case find_issue_id_for_ref(running, ref) do
          nil ->
            {:noreply, state}

          issue_id ->
            {running_entry, state} = pop_running_entry(state, issue_id)
            state = record_session_completion_totals(state, running_entry)
            session_id = running_entry_session_id(running_entry)

            state =
              state
              |> handle_worker_down_reason(issue_id, running_entry, reason, session_id)
              |> maybe_start_queued_operator_tasks()

            Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} exit=#{agent_exit_summary(reason, running_entry)}")

            notify_dashboard()
            {:noreply, state}
        end
      end

      def handle_info({:agent_runner_finished, issue_id, result}, %{running: running} = state)
          when is_binary(issue_id) do
        case Map.get(running, issue_id) do
          nil ->
            {:noreply, state}

          running_entry ->
            {:noreply,
             %{
               state
               | running: Map.put(running, issue_id, Map.put(running_entry, :agent_result, result))
             }}
        end
      end

      def handle_info(
            {:linear_task_update_result, issue_id, result, tool_result, references, target_state},
            %{running: running} = state
          ) do
        case Map.get(running, issue_id) do
          %RunningIssue{} = entry ->
            {:noreply,
             handle_linear_task_update_result(
               state,
               issue_id,
               entry,
               result,
               tool_result,
               references,
               target_state
             )}

          _missing ->
            {:noreply, state}
        end
      end

      def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
          when is_binary(issue_id) and is_map(runtime_info) do
        case Map.get(running, issue_id) do
          nil ->
            {:noreply, state}

          running_entry ->
            updated_running_entry =
              running_entry
              |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
              |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
              |> append_session_history(:workspace_ready, "Workspace ready", %{
                workspace_path: runtime_info[:workspace_path],
                worker_host: runtime_info[:worker_host]
              })

            persist_workspace_update(updated_running_entry)
            notify_dashboard()
            {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        end
      end

      def handle_info({:system_worker_update, issue_id, update}, %{running: running} = state)
          when is_binary(issue_id) and is_map(update) do
        case Map.get(running, issue_id) do
          nil ->
            {:noreply, state}

          running_entry ->
            updated_running_entry = append_system_history(running_entry, update)

            notify_dashboard()
            {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        end
      end

      def handle_info(
            {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
            %{running: running} = state
          ) do
        case Map.get(running, issue_id) do
          nil ->
            {:noreply, state}

          running_entry ->
            {:noreply, handle_codex_worker_update(state, issue_id, running_entry, update)}
        end
      end

      def handle_info({:codex_worker_update, _issue_id, _update}, state) do
        {:noreply, state}
      end

      def handle_info({:linear_state_transition, issue_id, transition}, %{running: running} = state)
          when is_binary(issue_id) and is_map(transition) do
        case Map.get(running, issue_id) do
          nil ->
            {:noreply, state}

          running_entry ->
            transitions = [transition | Map.get(running_entry, :linear_state_transitions, [])]

            updated_entry =
              running_entry
              |> Map.put(:linear_state_transitions, transitions)
              |> put_in([Access.key(:issue), Access.key(:state)], Map.get(transition, :to_state))
              |> append_session_history(:linear_state_transition, "Linear state moved", %{
                from_state: Map.get(transition, :from_state),
                to_state: Map.get(transition, :to_state),
                source: Map.get(transition, :source)
              })

            persist_event("linear.state_transition", running_entry.identifier, %{
              issue_id: issue_id,
              from_state: Map.get(transition, :from_state),
              to_state: Map.get(transition, :to_state),
              source: inspect(Map.get(transition, :source))
            })

            notify_dashboard()
            {:noreply, %{state | running: Map.put(running, issue_id, updated_entry)}}
        end
      end

      def handle_info({:retry_issue, issue_id, retry_token}, state) do
        result =
          case pop_retry_attempt_state(state, issue_id, retry_token) do
            {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
            :missing -> {:noreply, state}
          end

        notify_dashboard()
        result
      end

      def handle_info({:retry_issue, _issue_id}, state) do
        {:noreply, state}
      end

      def handle_info(msg, state) do
        Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
        {:noreply, state}
      end

      defp handle_linear_task_update_result(
             state,
             issue_id,
             entry,
             result,
             tool_result,
             references,
             target_state
           ) do
        blocker = tool_result |> blocker_value() |> BlockingDecision.normalize_blocker()

        cond do
          match?({:error, _}, result) ->
            reason = elem(result, 1)

            state
            |> handle_agent_domain_failure(issue_id, entry, reason, entry.session_id)
            |> Map.update!(:running, &Map.delete(&1, issue_id))

          is_binary(blocker) ->
            persist_and_block_issue(
              state,
              issue_id,
              entry,
              :reported_blocker,
              blocker,
              references
            )

          match?({:ok, %{"handoff" => _}}, result) ->
            updated = %{entry | implementation_handoff_completed: true}
            _ = BlockingDecision.clear(entry.identifier)
            %{state | running: Map.put(state.running, issue_id, updated)}

          is_binary(target_state) and match?({:ok, _}, result) ->
            _ = BlockingDecision.clear(entry.identifier)
            state

          true ->
            state
        end
      end

      defp handle_worker_task_finished(state, issue_id, outcome)
           when outcome in [:success, :cancelled] do
        {running_entry, state} = pop_running_entry(state, issue_id)

        state
        |> record_session_completion_totals(running_entry)
        |> complete_issue(issue_id)
      end

      defp handle_worker_task_finished(state, issue_id, {:blocked, reason}) do
        case Map.get(state.running, issue_id) do
          %RunningIssue{} = running_entry ->
            state = record_session_completion_totals(state, running_entry)

            references =
              running_entry
              |> run_references()
              |> Map.put(:session_id, running_entry.session_id)

            persist_and_block_issue(
              state,
              issue_id,
              running_entry,
              reason,
              reason,
              references
            )

          nil ->
            Logger.warning("Worker reported a blocked terminal outcome without a running entry issue_id=#{issue_id}; releasing claim")

            complete_issue(state, issue_id)
        end
      end

      defp handle_worker_task_finished(state, issue_id, {:failed, reason}) do
        case Map.get(state.running, issue_id) do
          %RunningIssue{} = running_entry ->
            summary = agent_failure_summary(reason)

            Logger.warning("Worker task failed for issue_id=#{issue_id} session_id=#{running_entry.session_id} #{summary}")

            state
            |> record_session_completion_totals(running_entry)
            |> fail_or_retry(
              issue_id,
              running_entry,
              summary,
              :failure_retries_exhausted,
              reason,
              record_environment_failure: false
            )
            |> Map.update!(:running, &Map.delete(&1, issue_id))

          nil ->
            Logger.warning("Worker reported a failed terminal outcome without a running entry issue_id=#{issue_id}; releasing claim")

            complete_issue(state, issue_id)
        end
      end

      defp handle_worker_down_reason(
             state,
             run_id,
             %RunningOperator{} = running_entry,
             reason,
             session_id
           ) do
        handle_operator_down_reason(state, run_id, running_entry, reason, session_id)
      end

      defp handle_worker_down_reason(
             state,
             issue_id,
             %RunningIssue{} = running_entry,
             reason,
             session_id
           ) do
        handle_issue_worker_down_reason(state, issue_id, running_entry, reason, session_id)
      end

      defp handle_issue_worker_down_reason(
             state,
             issue_id,
             %{agent_result: {:failed, reason}} = running_entry,
             :normal,
             session_id
           ) do
        handle_agent_domain_failure(state, issue_id, running_entry, reason, session_id)
      end

      defp handle_issue_worker_down_reason(
             state,
             issue_id,
             %{agent_result: {:blocked, outcome}} = running_entry,
             :normal,
             session_id
           ) do
        block_issue_for_input(state, issue_id, running_entry, outcome, session_id)
      end

      defp handle_issue_worker_down_reason(state, issue_id, running_entry, :normal, session_id) do
        persist_run_finished(running_entry, "completed", nil)
        EnvironmentFailureCircuit.record_success(running_entry.identifier)

        state = clear_failure_count(state, issue_id)

        if run_made_progress?(running_entry) do
          _ = BlockingDecision.clear(running_entry.identifier)
          schedule_continuation(state, issue_id, running_entry, session_id)
        else
          case BlockingDecision.advance_no_progress(
                 running_entry.identifier,
                 running_entry.run_id,
                 run_references(running_entry)
               ) do
            {:blocked, decision} ->
              block_from_decision(state, issue_id, running_entry, decision)

            {:streak, streak} ->
              persist_event(
                "run.no_progress",
                running_entry.identifier,
                %{streak: streak},
                running_entry.run_id
              )

              schedule_continuation(state, issue_id, running_entry, session_id)

            {:error, reason} ->
              Logger.error("Unable to persist no-progress decision issue_id=#{issue_id} run_id=#{running_entry.run_id} reason=#{inspect(reason)}")

              state |> complete_issue(issue_id)
          end
        end
      end

      defp handle_issue_worker_down_reason(state, issue_id, running_entry, reason, session_id) do
        Logger.warning("Agent task crashed for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason, limit: 20, printable_limit: 1000)}; scheduling retry")

        summary = "agent crashed: #{inspect(reason, limit: 20, printable_limit: 1000)}"

        fail_or_retry(state, issue_id, running_entry, summary, :worker_crash, reason)
        |> tap(fn _state -> persist_run_finished(running_entry, "failed", summary) end)
      end

      defp schedule_continuation(state, issue_id, running_entry, session_id) do
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          delay_type: :continuation,
          project_id: Map.get(running_entry, :project_id),
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
      end

      defp run_made_progress?(running_entry) do
        running_entry.linear_state_transitions != [] or running_entry.implementation_handoff_completed
      end

      defp blocker_value(result) when is_map(result) do
        Payload.get_any(result, ["blockers", :blockers])
      end

      defp blocker_value(_result) do
        nil
      end

      defp persist_and_block_issue(state, issue_id, running_entry, reason, evidence, references) do
        case BlockingDecision.decide(
               running_entry.identifier,
               reason,
               evidence,
               running_entry.run_id,
               references
             ) do
          {:ok, decision} ->
            block_from_decision(state, issue_id, running_entry, decision)

          {:error, persist_reason} ->
            Logger.error("Blocking decision persistence failed issue_id=#{issue_id} run_id=#{running_entry.run_id} reason=#{inspect(persist_reason)}")

            state
        end
      end

      defp block_from_decision(state, issue_id, running_entry, decision) do
        delivery = deliver_blocking_decision(issue_id, running_entry)

        persist_event(
          "run.blocked",
          running_entry.identifier,
          %{
            issue_id: issue_id,
            decision: decision,
            delivery_result: inspect(delivery)
          },
          running_entry.run_id
        )

        blocked_entry = %{
          issue_id: issue_id,
          identifier: running_entry.identifier,
          state:
            if delivery_transition_completed?(delivery) do
              "Blocked"
            else
              running_entry.issue.state
            end,
          run_id: running_entry.run_id,
          blocked_at: decision["decided_at"],
          reason: decision["reason"],
          detail: decision["evidence"],
          worker_host: running_entry.worker_host,
          workspace_path: running_entry.workspace_path,
          session_id: running_entry.session_id,
          project_id: running_entry.project_id,
          session_history: [],
          session_history_total_count: 0
        }

        cancel_issue_retry(state, issue_id)
        |> Map.update!(:running, &Map.delete(&1, issue_id))
        |> Map.update!(:blocked, &Map.put(&1, issue_id, blocked_entry))
        |> Map.update!(:claimed, &MapSet.put(&1, issue_id))
        |> clear_failure_count(issue_id)
      end

      defp deliver_blocking_decision(issue_id, %RunningIssue{} = running_entry) do
        case blocking_delivery_workflow(running_entry) do
          {:ok, workflow} ->
            delivery =
              Config.with_workflow_context(workflow, fn ->
                BlockingDecision.deliver(issue_id, running_entry.identifier)
              end)

            log_blocking_delivery_errors(issue_id, running_entry.identifier, delivery)
            delivery

          {:error, reason} ->
            delivery_reason = {:workflow_context_unavailable, reason}
            delivery = BlockingDecision.fail_delivery(running_entry.identifier, delivery_reason)
            log_blocking_delivery_errors(issue_id, running_entry.identifier, delivery)
            delivery
        end
      end

      defp blocking_delivery_workflow(%{project_id: project_id}) when is_binary(project_id) do
        WorkflowStore.for_project(project_id)
      end

      defp blocking_delivery_workflow(_running_entry) do
        {:error, :missing_project_context}
      end

      defp log_blocking_delivery_errors(issue_id, identifier, {:ok, delivery}) when is_map(delivery) do
        [:comment, :transition]
        |> Enum.each(fn step ->
          case Map.get(delivery, step) do
            {:error, reason} ->
              Logger.error("Blocking decision delivery step failed issue_id=#{issue_id} issue_identifier=#{identifier} step=#{step} reason=#{inspect(reason)}")

            _result ->
              :ok
          end
        end)
      end
    end
  end
end
