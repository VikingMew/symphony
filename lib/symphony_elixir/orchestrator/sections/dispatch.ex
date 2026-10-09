# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Dispatch do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
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
      alias SymphonyElixir.Linear.{DispatchScope, Issue}
      alias SymphonyElixir.Orchestrator.DispatchPolicy
      alias SymphonyElixir.Orchestrator.Events
      alias SymphonyElixir.Orchestrator.InputBlocker
      alias SymphonyElixir.Orchestrator.RetryPolicy
      alias SymphonyElixir.Orchestrator.{RunningIssue, RunningOperator, State}
      alias SymphonyElixir.Orchestrator.SessionHistory
      alias SymphonyElixir.Worker.AssignmentManager
      alias SymphonyElixir.Workspace.{Remote, SourcePreparation}

      defp dispatch_policy_settings(%State{} = state),
        do: dispatch_policy_settings(listening_mode_atom(state), state.max_concurrent_agents)

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

        if routed_states == [], do: ["refining"], else: routed_states
      end

      defp worker_policy_settings do
        config = Config.settings!()

        %{
          ssh_hosts: config.worker.ssh_hosts,
          max_concurrent_agents_per_host: config.worker.max_concurrent_agents_per_host
        }
      end

      defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
        case DispatchPolicy.revalidate_issue_for_dispatch(
               issue,
               &Tracker.fetch_issue_states_by_ids/1,
               dispatch_policy_settings(state)
             ) do
          {:ok, %Issue{} = refreshed_issue} ->
            case resolve_refreshed_context(refreshed_issue) do
              {:ok, resolved_issue} ->
                do_dispatch_issue(state, resolved_issue, attempt, preferred_worker_host)

              {:error, reason, rejected_issue} ->
                log_poll_context_rejection(rejected_issue, reason)
                state
            end

          {:skip, :missing} ->
            Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

            state

          {:skip, %Issue{} = refreshed_issue} ->
            Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

            state

          {:error, reason} ->
            Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

            state
        end
      end

      defp resolve_refreshed_context(issue) do
        workflows = WorkflowStore.list_enabled()
        scope = Config.settings!().dispatch_scope

        with {:ok, current} <- current_workflow_context(),
             {:ok, resolved_workflow, resolved_issue} <- DispatchScope.resolve_context(issue, workflows, scope),
             true <- resolved_workflow.project_id == current.project_id do
          {:ok, resolved_issue}
        else
          {:error, reason, rejected_issue} ->
            {:error, reason, rejected_issue}

          {:error, reason} ->
            {:error, reason, %{issue | dispatch_scope: DispatchScope.normalize_dispatch_scope(scope)}}

          false ->
            normalized_scope = DispatchScope.normalize_dispatch_scope(scope)
            {:error, :issue_project_out_of_scope, %{issue | dispatch_scope: normalized_scope}}
        end
      end

      defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host),
        do: dispatch_issue_centrally(state, issue, attempt, preferred_worker_host)

      defp dispatch_issue_centrally(%State{} = state, issue, attempt, preferred_worker_host) do
        recipient = self()

        case select_worker_host(state, preferred_worker_host) do
          :no_worker_capacity ->
            Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

            state

          worker_host ->
            admit_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
        end
      end

      defp admit_issue_on_worker_host(state, issue, attempt, recipient, worker_host) do
        case current_workflow_context() do
          {:ok, workflow} ->
            case RunAdmission.resolve(
                   workflow,
                   {:issue, issue},
                   centralized_execution_context(worker_host)
                 ) do
              {:ok, admission} ->
                persist_and_dispatch_issue(
                  state,
                  issue,
                  attempt,
                  recipient,
                  worker_host,
                  workflow,
                  admission
                )

              {:error, {:environment_unavailable, evidence}} ->
                skip_dispatch_for_admission(state, issue, evidence)
            end

          {:error, reason} ->
            skip_dispatch_for_workflow_context(state, issue, reason)
        end
      end

      defp persist_and_dispatch_issue(state, issue, attempt, recipient, worker_host, workflow, admission) do
        case persist_run_started(issue, attempt, worker_host, admission) do
          {:ok, run_record} ->
            dispatch_issue_agent(
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              workflow,
              run_record,
              admission
            )

          {:error, reason} ->
            skip_dispatch_for_persistence(
              state,
              issue,
              attempt,
              worker_host,
              workflow,
              admission,
              reason
            )
        end
      end

      defp dispatch_issue_agent(state, issue, attempt, recipient, worker_host, workflow, run_record, admission) do
        case start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow, admission) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

            running =
              Map.put(state.running, issue.id, %RunningIssue{
                pid: pid,
                ref: ref,
                run_id: run_record && run_record.id,
                identifier: issue.identifier,
                issue: issue,
                project_id: Map.get(workflow, :project_id),
                worker_host: worker_host,
                workspace_path: nil,
                session_id: nil,
                last_codex_message: nil,
                last_codex_timestamp: nil,
                last_codex_event: nil,
                codex_app_server_pid: nil,
                codex_input_tokens: 0,
                codex_output_tokens: 0,
                codex_total_tokens: 0,
                codex_last_reported_input_tokens: 0,
                codex_last_reported_output_tokens: 0,
                codex_last_reported_total_tokens: 0,
                turn_count: 0,
                retry_attempt: RetryPolicy.normalize_attempt(attempt),
                failure_count: Map.get(state.failure_counts, issue.id, 0),
                started_at: DateTime.utc_now(),
                admission: admission,
                session_history: initial_session_history(issue, attempt, worker_host),
                session_history_total_count: 1
              })

            %{
              state
              | running: running,
                claimed: MapSet.put(state.claimed, issue.id),
                retry_attempts: Map.delete(state.retry_attempts, issue.id)
            }

          {:error, reason} ->
            Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")

            persist_event("run.spawn_failed", issue.identifier, %{
              issue_id: issue.id,
              error: inspect(reason)
            })

            failure_reason = "failed to spawn agent: #{inspect(reason)}"

            failure =
              RunFailure.classify({:agent_domain_failure, %{reason: reason, detail: failure_reason, phase: "spawn"}})

            record_environment_failure(
              issue.id,
              %{identifier: issue.identifier, run_id: run_record && run_record.id},
              failure
            )

            persist_run_finished(
              %{
                run_id: run_record && run_record.id,
                identifier: issue.identifier,
                issue: issue,
                session_id: nil,
                admission: admission
              },
              "failed",
              failure
            )

            next_attempt = next_spawn_attempt(attempt)

            schedule_issue_retry(state, issue.id, next_attempt, %{
              identifier: issue.identifier,
              error: failure_reason,
              project_id: Map.get(workflow, :project_id),
              worker_host: worker_host,
              workspace_authority: admission.workspace_authority
            })
        end
      end

      defp start_operator_task_after_run(state, started, run, workflow, worker_host, admission) do
        started = if run, do: %{started | run_id: run.id}, else: started
        spawn_operator_task(state, started, worker_host, workflow, admission)
      end

      defp skip_dispatch_for_persistence(
             state,
             issue,
             attempt,
             worker_host,
             workflow,
             admission,
             reason
           ) do
        Logger.error("Run-start persistence failed action=skip_dispatch #{issue_context(issue)} reason=#{inspect(reason, limit: 20, printable_limit: 1_000)}")

        schedule_issue_retry(state, issue.id, next_spawn_attempt(attempt), %{
          identifier: issue.identifier,
          error: "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1_000)}",
          project_id: Map.get(workflow, :project_id),
          worker_host: worker_host,
          workspace_authority: admission.workspace_authority
        })
      end

      defp skip_dispatch_for_workflow_context(state, issue, reason) do
        Logger.error("Skipping dispatch; workflow context unavailable #{issue_context(issue)} reason=#{inspect(reason)}")
        release_issue_claim(state, issue.id)
      end

      defp skip_dispatch_for_admission(state, issue, evidence) do
        Logger.warning("Skipping dispatch; environment unavailable #{issue_context(issue)} evidence=#{inspect(evidence)}")
        release_retry_ownership(state, issue.id)
      end

      defp next_spawn_attempt(attempt) when is_integer(attempt), do: attempt + 1
      defp next_spawn_attempt(_attempt), do: nil

      defp start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow, admission) do
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          Config.with_workflow_context(workflow, fn ->
            result =
              agent_runner().run(issue, recipient,
                attempt: attempt,
                worker_host: worker_host,
                admission: admission,
                max_turns: admission.limits.max_turns,
                rate_limit_snapshot: state.codex_rate_limits,
                rate_limit_settings: Config.settings!()
              )

            send(recipient, {:agent_runner_finished, issue.id, result})
            result
          end)
        end)
      end

      defp complete_issue(%State{} = state, issue_id) do
        %{
          state
          | completed: MapSet.put(state.completed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            failure_counts: Map.delete(state.failure_counts, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id)
        }
      end

      defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
           when is_binary(issue_id) and is_map(metadata) do
        previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})

        case retry_settings(metadata) do
          {:ok, settings} ->
            do_schedule_issue_retry(state, issue_id, attempt, metadata, previous_retry, settings)

          {:error, reason} ->
            Logger.warning("Skipping retry scheduling; workflow context unavailable for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")
            release_issue_claim(state, issue_id)
        end
      end

      defp do_schedule_issue_retry(state, issue_id, attempt, metadata, previous_retry, settings) do
        prepared_retry =
          RetryPolicy.prepare_retry(
            issue_id,
            attempt,
            retry_policy_metadata(metadata),
            previous_retry,
            settings.agent.max_retry_backoff_ms
          )

        retry_token = make_ref()

        due_at_ms =
          System.monotonic_time(:millisecond) + prepared_retry.delay_ms +
            @retry_due_at_display_grace_ms

        if is_reference(prepared_retry.old_timer_ref) do
          Process.cancel_timer(prepared_retry.old_timer_ref)
        end

        timer_ref =
          Process.send_after(self(), {:retry_issue, issue_id, retry_token}, prepared_retry.delay_ms)

        persist_retry_schedule(issue_id, prepared_retry)

        retry_entry =
          prepared_retry
          |> RetryPolicy.retry_entry(timer_ref, retry_token, due_at_ms)
          |> Map.put(
            :workspace_authority,
            metadata[:workspace_authority] || previous_retry[:workspace_authority]
          )

        %{
          state
          | retry_attempts:
              Map.put(
                state.retry_attempts,
                issue_id,
                retry_entry
              ),
            claimed: MapSet.put(state.claimed, issue_id)
        }
      end

      defp persist_retry_schedule(issue_id, %{delay_type: :continuation} = retry) do
        Logger.info("Scheduling continuation check issue_id=#{issue_id} issue_identifier=#{retry.identifier} in #{retry.delay_ms}ms")
        persist_event("run.continuation_scheduled", retry.identifier, %{issue_id: issue_id, delay_ms: retry.delay_ms})
      end

      defp persist_retry_schedule(issue_id, retry) do
        error_suffix = if is_binary(retry.error), do: " error=#{retry.error}", else: ""

        Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{retry.identifier} in #{retry.delay_ms}ms (attempt #{retry.attempt})#{error_suffix}")

        persist_event("run.retry_scheduled", retry.identifier, %{
          issue_id: issue_id,
          attempt: retry.attempt,
          delay_ms: retry.delay_ms,
          error: retry.error
        })
      end

      @spec retry_policy_metadata(map()) :: RetryPolicy.retry_metadata()
      defp retry_policy_metadata(metadata) do
        Map.take(metadata, [
          :identifier,
          :error,
          :project_id,
          :worker_host,
          :workspace_path,
          :failure_evidence,
          :failure_count,
          :delay_type
        ])
      end

      defp retry_settings(metadata) do
        case retry_workflow_context(metadata) do
          {:ok, workflow} -> Config.with_workflow_context(workflow, &Config.settings/0)
          {:error, reason} -> {:error, reason}
        end
      end

      defp retry_workflow_context(%{project_id: project_id}) when is_binary(project_id) do
        WorkflowStore.for_project(project_id)
      end

      defp retry_workflow_context(_metadata), do: current_workflow_context()

      defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
           when is_reference(retry_token) do
        workspace_authority = get_in(state.retry_attempts, [issue_id, :workspace_authority])

        case RetryPolicy.pop_retry_attempt(state.retry_attempts, issue_id, retry_token) do
          {:ok, attempt, metadata, retry_attempts} ->
            {:ok, attempt, Map.put(metadata, :workspace_authority, workspace_authority), %{state | retry_attempts: retry_attempts}}

          :missing ->
            :missing
        end
      end

      defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
        case retry_workflow_context(metadata) do
          {:ok, workflow} ->
            Config.with_workflow_context(workflow, fn ->
              handle_retry_issue_with_workflow(state, issue_id, attempt, metadata)
            end)

          {:error, reason} ->
            Logger.warning("Skipping retry dispatch; workflow context unavailable for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")
            {:noreply, release_issue_claim(state, issue_id)}
        end
      end

      defp handle_retry_issue_with_workflow(%State{} = state, issue_id, attempt, metadata) do
        case environment_failure_circuit_allows_dispatch() do
          :allow ->
            case Tracker.fetch_candidate_issues() do
              {:ok, issues} ->
                issues
                |> find_issue_by_id(issue_id)
                |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

              {:error, reason} ->
                Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

                {:noreply,
                 schedule_issue_retry(
                   state,
                   issue_id,
                   attempt + 1,
                   Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
                 )}
            end

          {:environment_failure_circuit_open, circuit} ->
            Logger.warning(
              "Retry dispatch paused by environment failure circuit issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} fingerprint=#{circuit.triggering_fingerprint}"
            )

            {:noreply,
             schedule_issue_retry(
               state,
               issue_id,
               attempt,
               Map.merge(metadata, %{error: "environment failure circuit open: #{circuit.triggering_fingerprint}"})
             )}
        end
      end

      defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
        dispatch_settings = dispatch_policy_settings(state)
        terminal_states = Map.fetch!(dispatch_settings, :terminal_states)

        cond do
          terminal_issue_state?(issue.state, terminal_states) ->
            Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

            cleanup_issue_workspace(issue.identifier, metadata[:workspace_authority])
            {:noreply, release_issue_claim(state, issue_id)}

          DispatchPolicy.retry_candidate_issue?(issue, dispatch_settings) ->
            handle_active_retry(state, issue, attempt, metadata)

          true ->
            Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

            {:noreply, release_issue_claim(state, issue_id)}
        end
      end

      defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
        Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
        {:noreply, release_issue_claim(state, issue_id)}
      end

      defp cleanup_issue_workspace(identifier, authority)
           when is_binary(identifier) and
                  (authority == {:panel_local} or elem(authority, 0) == :centralized_ssh) do
        Workspace.remove_issue_workspaces(identifier, authority)
      end

      defp cleanup_issue_workspace(_identifier, {:http_worker, _worker_id, _session_id}), do: :ok

      defp run_terminal_workspace_cleanup do
        case WorkflowStore.list_enabled() do
          [] ->
            :ok

          workflows ->
            Enum.each(workflows, &run_terminal_workspace_cleanup_for_workflow/1)
        end
      end

      defp run_terminal_workspace_cleanup_for_workflow(workflow) do
        workflow
        |> RunAdmission.cleanup_authorities()
        |> run_terminal_workspace_cleanup_for_authorities(workflow)
      end

      defp run_terminal_workspace_cleanup_for_authorities([], _workflow), do: :ok

      defp run_terminal_workspace_cleanup_for_authorities(authorities, workflow) do
        Config.with_workflow_context(workflow, fn ->
          with {:ok, settings} <- Config.settings(),
               :ok <- Config.validate_settings(settings),
               {:ok, issues} <- Tracker.fetch_issues_by_states(settings.tracker.terminal_states) do
            cleanup_terminal_issue_workspaces(issues, authorities)
          else
            {:error, reason} ->
              log_terminal_workspace_cleanup_skip(reason)
          end
        end)
      end

      defp cleanup_terminal_issue_workspaces(issues, authorities) when is_list(issues) do
        Enum.each(issues, fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            Enum.each(authorities, &cleanup_issue_workspace(identifier, &1))

          _issue ->
            :ok
        end)
      end

      defp log_terminal_workspace_cleanup_skip(reason) do
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{config_validation_error_message(reason)}")
      end

      defp notify_dashboard do
        StatusDashboard.notify_update()
      end

      defp handle_active_retry(state, issue, attempt, metadata) do
        case current_workflow_context() do
          {:ok, workflow} ->
            Config.with_workflow_context(workflow, fn ->
              handle_active_retry_with_workflow(state, issue, attempt, metadata)
            end)

          {:error, reason} ->
            Logger.warning("Skipping retry dispatch; workflow context unavailable for #{issue_context(issue)}: #{inspect(reason)}")
            {:noreply, release_issue_claim(state, issue.id)}
        end
      end

      defp handle_active_retry_with_workflow(state, issue, attempt, metadata) do
        state = refresh_deployment_capacity(state)

        if RunAdmission.execution_mode() == "worker" do
          {:noreply, release_retry_ownership(state, issue.id)}
        else
          dispatch_settings = dispatch_policy_settings(state)
          worker_settings = worker_policy_settings()

          if DispatchPolicy.retry_candidate_issue?(issue, dispatch_settings) and
               dispatch_slots_available?(issue, state) and
               DispatchPolicy.worker_slots_available?(state, metadata[:worker_host], worker_settings) do
            {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
          else
            Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

            {:noreply,
             schedule_issue_retry(
               state,
               issue.id,
               attempt + 1,
               Map.merge(metadata, %{
                 identifier: issue.identifier,
                 error: "no available orchestrator slots"
               })
             )}
          end
        end
      end

      defp release_retry_ownership(%State{} = state, issue_id) do
        %{
          state
          | claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
      end

      defp release_issue_claim(%State{} = state, issue_id) do
        %{
          state
          | claimed: MapSet.delete(state.claimed, issue_id),
            failure_counts: Map.delete(state.failure_counts, issue_id)
        }
      end

      defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

      defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
        Map.put(running_entry, key, value)
      end

      defp select_worker_host(%State{} = state, preferred_worker_host) do
        DispatchPolicy.select_worker_host(state, preferred_worker_host, worker_policy_settings())
      end

      defp centralized_execution_context(nil), do: %{workspace_authority: {:panel_local}}

      defp centralized_execution_context(worker_host) when is_binary(worker_host) do
        %{
          workspace_authority: {:centralized_ssh, worker_host},
          readiness: &ssh_workspace_readiness/2
        }
      end

      defp ssh_workspace_readiness({:centralized_ssh, worker_host}, settings) do
        settings
        |> ssh_workspace_roots()
        |> Enum.reduce_while(:ok, fn root, :ok ->
          case check_ssh_workspace_root(worker_host, root, settings) do
            :ok -> {:cont, :ok}
            {:error, rejection} -> {:halt, {:error, rejection}}
          end
        end)
      end

      defp ssh_workspace_roots(settings) do
        [
          settings.workspace.root,
          SourcePreparation.repository_base_root(settings),
          SourcePreparation.worktree_base_root(settings)
        ]
        |> Enum.uniq()
      end

      defp check_ssh_workspace_root(worker_host, root, settings) do
        script = ssh_workspace_preflight_script(root, settings.workspace.min_free_bytes)

        case Remote.run_command(worker_host, script, settings.workspace.initialize_timeout_ms) do
          {:ok, {output, 0}} ->
            parse_ssh_workspace_preflight(output, root, settings.workspace.min_free_bytes)

          {:ok, {output, status}} ->
            {:error, %{kind: :ssh_unavailable, path: root, reason: {:exit_status, status, output}}}

          {:error, reason} ->
            {:error, %{kind: :ssh_unavailable, path: root, reason: reason}}
        end
      end

      defp ssh_workspace_preflight_script(root, min_free_bytes) do
        [
          "set -u",
          Remote.shell_assign("root", root),
          "candidate=\"$root\"",
          "probe_kind=not_writable",
          "if [ ! -e \"$candidate\" ]; then",
          "  probe_kind=not_creatable",
          "  while [ ! -e \"$candidate\" ]; do",
          "    parent=$(dirname \"$candidate\")",
          "    if [ \"$parent\" = \"$candidate\" ]; then printf '%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' 'not_creatable'; exit 0; fi",
          "    candidate=\"$parent\"",
          "  done",
          "fi",
          "if [ ! -d \"$candidate\" ]; then printf '%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' 'not_creatable'; exit 0; fi",
          "probe=\"$candidate/.symphony-write-probe-$$\"",
          "if ! mkdir \"$probe\" 2>/dev/null; then printf '%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' \"$probe_kind\"; exit 0; fi",
          "rmdir \"$probe\"",
          ssh_disk_preflight_script(min_free_bytes),
          "printf '%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' 'ok'"
        ]
        |> Enum.join("\n")
      end

      defp ssh_disk_preflight_script(min_free_bytes) when min_free_bytes <= 0, do: ""

      defp ssh_disk_preflight_script(min_free_bytes) do
        [
          "available_kb=$(df -Pk \"$candidate\" 2>/dev/null | awk 'NR == 2 {print $4}')",
          "case \"$available_kb\" in ''|*[!0-9]*) printf '%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' 'disk_space_unavailable'; exit 0 ;; esac",
          "free_bytes=$((available_kb * 1024))",
          "if [ \"$free_bytes\" -lt '#{min_free_bytes}' ]; then printf '%s\\t%s\\t%s\\n' '__SYMPHONY_PREFLIGHT__' 'low_disk_space' \"$free_bytes\"; exit 0; fi"
        ]
        |> Enum.join("\n")
      end
    end
  end
end
