# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Reconciliation do
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

      defp maybe_dispatch(%State{} = state) do
        Logger.debug("event=poll_heartbeat listening_mode=#{listening_mode(state)} tick_timestamp=#{System.system_time(:millisecond)}")

        state =
          state
          |> reconcile_stale_operator_entries()
          |> reconcile_running_issues()
          |> reconcile_blocked_issues()
          |> refresh_deployment_capacity()

        workflows = WorkflowStore.list_enabled()

        if workflows == [] do
          handle_dispatch_error(state, :setup_required)
        else
          Enum.reduce(workflows, state, &dispatch_workflow/2)
        end
      end

      defp dispatch_workflow(workflow, state) do
        Config.with_workflow_context(workflow, fn ->
          dispatch_for_workflow(state, workflow)
        end)
      end

      defp dispatch_for_workflow(%State{} = state, %{config: _config} = workflow) do
        if Config.execution_mode() == :worker do
          state
        else
          dispatch_for_workflow_centrally(state, workflow)
        end
      end

      defp dispatch_for_workflow_centrally(%State{} = state, workflow) do
        with :ok <- Config.validate!(),
             state = reconcile_ready_to_merge_issues(state),
             :allow <- environment_failure_circuit_allows_dispatch(),
             :allow <- rate_limit_gate_allows_dispatch(state),
             {:ok, issues} <- Tracker.fetch_candidate_issues(),
             true <- available_slots(state) > 0,
             true <- workflow_slots_available?(state, workflow) do
          Logger.info(
            "event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=success candidate_count=#{length(issues)} dispatch=attempted"
          )

          state = %{state | last_config_error: nil}
          persist_polled_issues(issues)
          choose_issues(issues, state)
        else
          {:error, reason} ->
            Logger.warning("event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=failed reason=#{inspect(reason)} dispatch=blocked")

            handle_dispatch_error(state, reason)

          {:block, details} ->
            state
            |> apply_rate_limit_gate_block(details)
            |> Map.put(:last_config_error, nil)

          {:environment_failure_circuit_open, circuit} ->
            Logger.warning(
              "event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} dispatch=blocked reason=environment_failure_circuit_open fingerprint=#{circuit.triggering_fingerprint}"
            )

            %{state | last_config_error: nil}

          false ->
            Logger.info("event=poll_workflow_decision listening_mode=#{listening_mode(state)} workflow=#{workflow_name(workflow)} candidate_fetch=success dispatch=skipped reason=capacity")

            %{state | last_config_error: nil}
        end
      end

      defp reconcile_ready_to_merge_issues(%State{} = state) do
        case Tracker.fetch_issues_by_states(["Ready to Merge"]) do
          {:ok, issues} ->
            persist_polled_issues(issues)

            issues
            |> Enum.take(@mergeability_checks_per_poll)
            |> Enum.reduce(state, fn
              %Issue{} = issue, state_acc -> reconcile_ready_to_merge_issue(state_acc, issue)
              _issue, state_acc -> state_acc
            end)

          {:error, reason} ->
            Logger.error("Failed to fetch Ready to Merge issues for mergeability reconciliation: #{inspect(reason)}")

            state
        end
      end

      defp reconcile_ready_to_merge_issue(state, issue) do
        case MergeConflictReconciler.reconcile(issue, Config.settings!().project) do
          {:blocked, decision, delivery} ->
            blocked_entry = %{
              issue_id: issue.id,
              identifier: issue.identifier,
              state:
                if delivery_transition_completed?(delivery) do
                  "Blocked"
                else
                  issue.state
                end,
              run_id: decision["run_id"],
              blocked_at: decision["decided_at"],
              reason: decision["reason"],
              detail: decision["evidence"],
              worker_host: nil,
              workspace_path: nil,
              session_id: nil,
              session_history: [],
              session_history_total_count: 0
            }

            state
            |> Map.update!(:blocked, &Map.put(&1, issue.id, blocked_entry))
            |> Map.update!(:claimed, &MapSet.put(&1, issue.id))

          _result ->
            state
        end
      end

      defp workflow_slots_available?(%State{} = state, _workflow) do
        available_slots(state) > 0
      end

      defp handle_dispatch_error(%State{} = state, reason) do
        if config_validation_error?(reason) do
          log_config_error_once(state, reason)
        else
          Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
          %{state | last_config_error: nil}
        end
      end

      defp log_config_error_once(%State{last_config_error: reason} = state, reason) do
        state
      end

      defp log_config_error_once(%State{} = state, reason) do
        Logger.error(config_validation_error_message(reason))
        %{state | last_config_error: reason}
      end

      defp config_validation_error?(:missing_linear_api_token) do
        true
      end

      defp config_validation_error?(:missing_linear_endpoint) do
        true
      end

      defp config_validation_error?(:missing_linear_project_slug) do
        true
      end

      defp config_validation_error?(:missing_project_repository_url) do
        true
      end

      defp config_validation_error?(:missing_tracker_kind) do
        true
      end

      defp config_validation_error?(:setup_required) do
        true
      end

      defp config_validation_error?(:workflow_front_matter_not_a_map) do
        true
      end

      defp config_validation_error?({:unsupported_tracker_kind, _kind}) do
        true
      end

      defp config_validation_error?({:invalid_workflow_config, _message}) do
        true
      end

      defp config_validation_error?({:missing_workflow_file, _path, _reason}) do
        true
      end

      defp config_validation_error?({:workflow_parse_error, _reason}) do
        true
      end

      defp config_validation_error?(_reason) do
        false
      end

      defp config_validation_error_message(:missing_linear_api_token) do
        "Linear API token missing in runtime environment"
      end

      defp config_validation_error_message(:missing_linear_endpoint) do
        "Linear endpoint missing in runtime tracker settings"
      end

      defp config_validation_error_message(:missing_linear_project_slug) do
        "Linear project slug missing in Project Settings"
      end

      defp config_validation_error_message(:missing_project_repository_url) do
        "Project repository URL missing in Project Settings"
      end

      defp config_validation_error_message(:missing_tracker_kind) do
        "Tracker kind missing in runtime tracker settings"
      end

      defp config_validation_error_message(:setup_required) do
        "No workflow is configured. Import a workflow package in /settings/import."
      end

      defp config_validation_error_message(:workflow_front_matter_not_a_map) do
        "Failed to parse workflow config: front matter must decode to a map"
      end

      defp config_validation_error_message({:unsupported_tracker_kind, kind}) do
        "Unsupported tracker kind in runtime tracker settings: #{inspect(kind)}"
      end

      defp config_validation_error_message({:invalid_workflow_config, message}) do
        "Invalid workflow config: #{message}"
      end

      defp config_validation_error_message({:missing_workflow_file, path, reason}) do
        "Missing workflow file at #{path}: #{inspect(reason)}"
      end

      defp config_validation_error_message({:workflow_parse_error, reason}) do
        "Failed to parse workflow config: #{inspect(reason)}"
      end

      defp config_validation_error_message(reason) do
        inspect(reason)
      end

      defp reconcile_running_issues(%State{} = state) do
        state = reconcile_stalled_running_issues(state)
        running_ids = issue_running_ids(state.running)

        if running_ids == [] do
          state
        else
          with {:ok, state_sets} <- runtime_state_sets(),
               {:ok, issues} <- Tracker.fetch_issue_states_by_ids(running_ids) do
            issues
            |> reconcile_running_issue_states(
              state,
              state_sets.active,
              state_sets.terminal
            )
            |> reconcile_missing_running_issue_ids(running_ids, issues)
          else
            {:error, reason} ->
              Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

              state
          end
        end
      end

      @doc "Reconciles already-refreshed issue states against the current runtime state.\n\nThis is a side-effecting runtime boundary used by the orchestrator and\nintegration tests. It may stop active tasks and clean workspaces according to\nthe configured active and terminal state sets.\n"
      @spec reconcile_issue_states([Issue.t()], term()) :: term()
      def reconcile_issue_states(issues, %State{} = state) when is_list(issues) do
        case runtime_state_sets() do
          {:ok, state_sets} ->
            reconcile_running_issue_states(issues, state, state_sets.active, state_sets.terminal)

          {:error, _reason} ->
            state
        end
      end

      def reconcile_issue_states(issues, state) when is_list(issues) do
        case runtime_state_sets() do
          {:ok, state_sets} ->
            reconcile_running_issue_states(issues, state, state_sets.active, state_sets.terminal)

          {:error, _reason} ->
            state
        end
      end

      defp reconcile_running_issue_states([], state, _active_states, _terminal_states) do
        state
      end

      defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
        reconcile_running_issue_states(
          rest,
          reconcile_issue_state(issue, state, active_states, terminal_states),
          active_states,
          terminal_states
        )
      end

      defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
        cond do
          terminal_issue_state?(issue.state, terminal_states) ->
            Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

            terminate_running_issue(state, issue.id, true)

          !DispatchPolicy.issue_routable_to_worker?(issue) ->
            Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

            terminate_running_issue(state, issue.id, false)

          active_issue_state?(issue.state, active_states) ->
            refresh_running_issue_state(state, issue)

          true ->
            Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

            terminate_running_issue(state, issue.id, false)
        end
      end

      defp reconcile_issue_state(_issue, state, _active_states, _terminal_states) do
        state
      end

      defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
           when is_list(requested_issue_ids) and is_list(issues) do
        visible_issue_ids =
          issues
          |> Enum.flat_map(fn
            %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
            _ -> []
          end)
          |> MapSet.new()

        Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
          if MapSet.member?(visible_issue_ids, issue_id) do
            state_acc
          else
            log_missing_running_issue(state_acc, issue_id)
            terminate_running_issue(state_acc, issue_id, false)
          end
        end)
      end

      defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues) do
        state
      end

      defp reconcile_blocked_issues(%State{blocked: blocked} = state) when map_size(blocked) == 0 do
        state
      end

      defp reconcile_blocked_issues(%State{blocked: blocked} = state) do
        blocked_ids = Map.keys(blocked)

        with {:ok, state_sets} <- runtime_state_sets(),
             {:ok, issues} <- Tracker.fetch_issue_states_by_ids(blocked_ids) do
          issues
          |> reconcile_blocked_issue_states(state, state_sets.active, state_sets.terminal)
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)
        else
          {:error, reason} ->
            Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked claims")

            state
        end
      end

      defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states) do
        state
      end

      defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
        reconcile_blocked_issue_states(
          rest,
          reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
          active_states,
          terminal_states
        )
      end

      defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
        cond do
          SymphonyElixir.StateName.normalize(issue.state) == "blocked" ->
            _ = retry_blocked_delivery(issue)
            refresh_blocked_issue_state(state, issue)

          terminal_issue_state?(issue.state, terminal_states) ->
            Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing blocked claim")

            _ = BlockingDecision.clear(issue.identifier)
            release_blocked_issue(state, issue.id)

          !DispatchPolicy.issue_routable_to_worker?(issue) ->
            Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing blocked claim")

            _ = BlockingDecision.clear(issue.identifier)
            release_blocked_issue(state, issue.id)

          active_issue_state?(issue.state, active_states) ->
            Logger.info("Blocked issue recovered to active state: #{issue_context(issue)} state=#{issue.state}; clearing decision")

            _ = BlockingDecision.clear(issue.identifier)
            release_blocked_issue(state, issue.id)

          true ->
            Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing blocked claim")

            _ = BlockingDecision.clear(issue.identifier)
            release_blocked_issue(state, issue.id)
        end
      end

      defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states) do
        state
      end

      defp retry_blocked_delivery(%Issue{id: issue_id, identifier: identifier}) do
        case BlockingDecision.deliver(issue_id, identifier) do
          {:ok, _delivery} ->
            :ok

          {:error, reason} ->
            Logger.error("Blocking decision delivery retry failed issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

            {:error, reason}
        end
      end

      defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
           when is_list(requested_issue_ids) and is_list(issues) do
        visible_issue_ids =
          issues
          |> Enum.flat_map(fn
            %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
            _ -> []
          end)
          |> MapSet.new()

        Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
          if MapSet.member?(visible_issue_ids, issue_id) do
            state_acc
          else
            release_blocked_issue(state_acc, issue_id)
          end
        end)
      end

      defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues) do
        state
      end

      defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
        case Map.get(state.blocked, issue.id) do
          %{} = blocked_entry ->
            %{
              state
              | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | state: issue.state})
            }

          _ ->
            state
        end
      end

      defp release_blocked_issue(%State{} = state, issue_id) do
        %{
          state
          | blocked: Map.delete(state.blocked, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
      end

      defp restore_persistent_blocked(%State{} = state) do
        persistence = persistence()

        case PersistenceProvider.read(fn -> persistence.list_blocked_issues() end) do
          issues when is_list(issues) ->
            Enum.reduce(issues, state, &restore_blocked_entry(&1, &2))

          {:error, reason} ->
            Logger.error("Failed to restore persistent blocking decisions reason=#{inspect(reason)}")
            state
        end
      end

      defp restore_blocked_entry(issue, acc) do
        decision = Map.get(issue, :blocking_decision) || %{}
        issue_id = Map.get(issue, :tracker_issue_id)

        if is_binary(issue_id) do
          entry = %{
            issue_id: issue_id,
            identifier: Map.get(issue, :identifier),
            state: Map.get(issue, :state) || "Blocked",
            run_id: decision["run_id"],
            blocked_at: decision["decided_at"],
            reason: decision["reason"],
            detail: decision["evidence"],
            worker_host: nil,
            workspace_path: nil,
            session_id: nil,
            session_history: [],
            session_history_total_count: 0
          }

          %{
            acc
            | blocked: Map.put(acc.blocked, issue_id, entry),
              claimed: MapSet.put(acc.claimed, issue_id)
          }
        else
          acc
        end
      end

      defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
        case Map.get(state.running, issue_id) do
          %{identifier: identifier} ->
            Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

          _ ->
            Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
        end
      end

      defp log_missing_running_issue(_state, _issue_id) do
        :ok
      end

      defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
        case Map.get(state.running, issue.id) do
          %{issue: _} = running_entry ->
            %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

          _ ->
            state
        end
      end

      defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
        case Map.get(state.running, issue_id) do
          nil ->
            release_issue_claim(state, issue_id)

          %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
            state = record_session_completion_totals(state, running_entry)
            worker_host = Map.get(running_entry, :worker_host)

            if cleanup_workspace do
              cleanup_issue_workspace(identifier, worker_host)
            end

            persist_run_finished(running_entry, "stopped", nil)

            if is_pid(pid) do
              terminate_task(pid)
            end

            if is_reference(ref) do
              Process.demonitor(ref, [:flush])
            end

            %{
              state
              | running: Map.delete(state.running, issue_id),
                claimed: MapSet.delete(state.claimed, issue_id),
                retry_attempts: Map.delete(state.retry_attempts, issue_id)
            }

          _ ->
            release_issue_claim(state, issue_id)
        end
      end

      defp reconcile_stalled_running_issues(%State{} = state) do
        if map_size(state.running) == 0 do
          state
        else
          do_reconcile_stalled_running_issues(state)
        end
      end

      defp do_reconcile_stalled_running_issues(state) do
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue_with_context(state_acc, issue_id, running_entry, now)
        end)
      end

      defp restart_stalled_issue_with_context(state, _issue_id, %RunningOperator{}, _now) do
        state
      end

      defp restart_stalled_issue_with_context(state, issue_id, %RunningIssue{} = running_entry, now) do
        case retry_settings(%{
               project_id: Map.get(running_entry, :project_id),
               identifier: running_entry.identifier
             }) do
          {:ok, settings} ->
            restart_stalled_issue(state, issue_id, running_entry, now, settings.codex.stall_timeout_ms)

          {:error, reason} ->
            Logger.warning("Skipping stalled issue check; workflow context unavailable issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} reason=#{inspect(reason)}")

            state
        end
      end

      defp restart_stalled_issue(state, _issue_id, _running_entry, _now, timeout_ms)
           when timeout_ms <= 0 do
        state
      end

      defp restart_stalled_issue(state, issue_id, %RunningIssue{} = running_entry, now, timeout_ms) do
        stall_decision = RetryPolicy.stall_decision(issue_id, running_entry, now, timeout_ms)

        case stall_decision do
          {:stalled, decision} ->
            Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{decision.identifier} session_id=#{decision.session_id} elapsed_ms=#{decision.elapsed_ms}; restarting with backoff")

            summary = decision.metadata.error

            state
            |> terminate_running_issue(issue_id, false)
            |> fail_or_retry(
              issue_id,
              running_entry,
              summary,
              :failure_retries_exhausted,
              %{kind: :stall, elapsed_ms: decision.elapsed_ms}
            )
            |> tap(fn _state -> persist_run_finished(running_entry, "failed", summary) end)

          :active ->
            state
        end
      end

      defp terminate_task(pid) when is_pid(pid) do
        case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Process.exit(pid, :shutdown)
        end
      end

      defp terminate_task(_pid) do
        :ok
      end

      defp choose_issues(issues, state) do
        dispatch_settings = dispatch_policy_settings(state)
        worker_settings = worker_policy_settings()

        issues
        |> DispatchPolicy.sort_issues_for_dispatch()
        |> Enum.reduce(state, fn issue, state_acc ->
          if DispatchPolicy.should_dispatch_issue?(
               issue,
               state_acc,
               dispatch_settings,
               worker_settings
             ) do
            dispatch_issue(state_acc, issue)
          else
            reasons = DispatchPolicy.skip_reasons(issue, state_acc, dispatch_settings, worker_settings)

            Logger.info("event=dispatch_skip issue_id=#{issue.id} issue_identifier=#{issue.identifier} skip_reason=#{Enum.join(reasons, ",")}")

            state_acc
          end
        end)
      end

      defp listening_mode(%State{} = state) do
        listening_mode_string(state)
      end

      defp workflow_name(%{project_id: project_id}) do
        project_id
      end

      defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
        DispatchPolicy.terminal_issue_state?(state_name, terminal_states)
      end

      defp terminal_issue_state?(_state_name, _terminal_states) do
        false
      end

      defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
        DispatchPolicy.active_issue_state?(state_name, active_states)
      end

      defp normalize_issue_state(state_name) when is_binary(state_name) do
        SymphonyElixir.StateName.normalize(state_name)
      end

      defp runtime_state_sets do
        with {:ok, settings} <- Config.settings() do
          {:ok,
           %{
             active: DispatchPolicy.normalized_state_set(settings.tracker.active_states),
             terminal: DispatchPolicy.normalized_state_set(settings.tracker.terminal_states)
           }}
        end
      end

      @spec dispatch_policy_settings(listening_mode(), pos_integer()) ::
              DispatchPolicy.dispatch_settings()
      def dispatch_policy_settings(listening_mode, max_concurrent_agents) do
        config = Config.settings!()

        DispatchPolicy.build_settings(%{
          active_states: config.tracker.active_states,
          terminal_states: config.tracker.terminal_states,
          refinement_states: refinement_states(config),
          listening_mode: listening_mode,
          max_concurrent_agents: max_concurrent_agents,
          workflow_executor_for_state: &Config.workflow_executor_for_state/1,
          human_review_state?: &Config.human_review_state?/1
        })
      end

      defp dispatch_policy_settings(%State{} = state) do
        dispatch_policy_settings(listening_mode_atom(state), state.max_concurrent_agents)
      end

      defp refinement_states(config) do
        routed_states =
          config.workflow
          |> Map.get("states", %{})
          |> Enum.flat_map(fn
            {state_name, %{"profile" => "refinement"}} when is_binary(state_name) -> [state_name]
            {state_name, %{profile: "refinement"}} when is_binary(state_name) -> [state_name]
            _ -> []
          end)
          |> Enum.map(&normalize_issue_state/1)
          |> Enum.reject(&(&1 == ""))

        if routed_states == [] do
          ["refining"]
        else
          routed_states
        end
      end

      defp worker_policy_settings do
        config = Config.settings!()

        %{
          ssh_hosts: config.worker.ssh_hosts,
          max_concurrent_agents_per_host: config.worker.max_concurrent_agents_per_host
        }
      end
    end
  end
end
