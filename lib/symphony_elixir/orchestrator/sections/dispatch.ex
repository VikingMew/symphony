# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Dispatch do
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

      defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
        case DispatchPolicy.revalidate_issue_for_dispatch(
               issue,
               &Tracker.fetch_issue_states_by_ids/1,
               dispatch_policy_settings(state)
             ) do
          {:ok, %Issue{} = refreshed_issue} ->
            do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

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

      defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
        dispatch_issue_centrally(state, issue, attempt, preferred_worker_host)
      end

      defp dispatch_issue_centrally(%State{} = state, issue, attempt, preferred_worker_host) do
        recipient = self()

        case select_worker_host(state, preferred_worker_host) do
          :no_worker_capacity ->
            Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

            state

          worker_host ->
            spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
        end
      end

      defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
        case ensure_workspace_disk_available(issue) do
          :ok ->
            spawn_issue_with_workflow_context(state, issue, attempt, recipient, worker_host)

          {:error, reason} ->
            block_issue_for_disk_guard(state, issue, reason, worker_host)
        end
      end

      defp spawn_issue_with_workflow_context(state, issue, attempt, recipient, worker_host) do
        case current_workflow_context() do
          {:ok, workflow} ->
            persist_and_dispatch_issue(state, issue, attempt, recipient, worker_host, workflow)

          {:error, reason} ->
            skip_dispatch_for_workflow_context(state, issue, reason)
        end
      end

      defp persist_and_dispatch_issue(state, issue, attempt, recipient, worker_host, workflow) do
        case persist_run_started(issue, attempt, worker_host) do
          {:ok, run_record} ->
            dispatch_issue_agent(
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              workflow,
              run_record
            )

          {:error, reason} ->
            skip_dispatch_for_persistence(state, issue, attempt, worker_host, workflow, reason)
        end
      end

      defp dispatch_issue_agent(state, issue, attempt, recipient, worker_host, workflow, run_record) do
        case start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow) do
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

            record_environment_failure(
              issue.id,
              %{identifier: issue.identifier, run_id: run_record && run_record.id},
              reason
            )

            persist_run_finished(
              %{
                run_id: run_record && run_record.id,
                identifier: issue.identifier,
                issue: issue,
                session_id: nil
              },
              "failed",
              failure_reason
            )

            next_attempt = next_spawn_attempt(attempt)

            schedule_issue_retry(state, issue.id, next_attempt, %{
              identifier: issue.identifier,
              error: failure_reason,
              project_id: Map.get(workflow, :project_id),
              worker_host: worker_host
            })
        end
      end

      defp start_operator_task_after_run(state, started, run, workflow) do
        started =
          if run do
            %{started | run_id: run.id}
          else
            started
          end

        case select_worker_host(state, nil) do
          :no_worker_capacity ->
            fail_operator_task_start(state, started, "no worker capacity available")

          worker_host ->
            spawn_operator_task_with_disk_guard(state, started, worker_host, workflow)
        end
      end

      defp spawn_operator_task_with_disk_guard(state, started, worker_host, workflow) do
        issue = operator_task_issue(started)

        case ensure_workspace_disk_available(issue) do
          :ok ->
            spawn_operator_task(state, started, worker_host, workflow)

          {:error, reason} ->
            fail_operator_task_start(state, started, format_disk_guard_reason(reason))
        end
      end

      defp skip_dispatch_for_persistence(state, issue, attempt, worker_host, workflow, reason) do
        Logger.error("Run-start persistence failed action=skip_dispatch #{issue_context(issue)} reason=#{inspect(reason, limit: 20, printable_limit: 1000)}")

        schedule_issue_retry(state, issue.id, next_spawn_attempt(attempt), %{
          identifier: issue.identifier,
          error: "run-start persistence failed: #{inspect(reason, limit: 20, printable_limit: 1000)}",
          project_id: Map.get(workflow, :project_id),
          worker_host: worker_host
        })
      end

      defp skip_dispatch_for_workflow_context(state, issue, reason) do
        Logger.error("Skipping dispatch; workflow context unavailable #{issue_context(issue)} reason=#{inspect(reason)}")

        release_issue_claim(state, issue.id)
      end

      defp next_spawn_attempt(attempt) when is_integer(attempt) do
        attempt + 1
      end

      defp next_spawn_attempt(_attempt) do
        nil
      end

      defp start_issue_agent_task(state, issue, attempt, recipient, worker_host, workflow) do
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          Config.with_workflow_context(workflow, fn ->
            result =
              agent_runner().run(issue, recipient,
                attempt: attempt,
                worker_host: worker_host,
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

      defp ensure_workspace_disk_available(issue) do
        case workspace_disk_guard().check(Config.settings!()) do
          {:ok, _summary} ->
            :ok

          {:error, reason} ->
            Logger.warning("Skipping agent spawn for #{issue_context(issue)}: #{format_disk_guard_reason(reason)}")

            {:error, reason}
        end
      rescue
        error ->
          reason = %{
            reason: :disk_guard_evaluation_failed,
            exception: error.__struct__,
            detail: Exception.message(error)
          }

          Logger.error("Workspace disk guard evaluation failed action=disk_guard_failed #{disk_guard_log_context(issue)} exception=#{inspect(reason.exception)} reason=#{inspect(reason.detail)}")

          {:error, reason}
      end

      defp disk_guard_log_context(%Issue{
             id: run_id,
             assigned_to_worker: false,
             labels: ["operator" | _]
           }) do
        "run_id=#{run_id}"
      end

      defp disk_guard_log_context(%Issue{} = issue) do
        issue_context(issue)
      end

      defp workspace_disk_guard do
        Application.get_env(:symphony_elixir, :workspace_disk_guard_module, WorkspaceDiskGuard)
      end

      defp block_issue_for_disk_guard(%State{} = state, %Issue{} = issue, reason, worker_host) do
        detail = format_disk_guard_reason(reason)

        persist_event("run.blocked", issue.identifier, %{
          issue_id: issue.id,
          reason: "workspace_disk_guard",
          detail: detail,
          root: Map.get(reason, :root),
          free_bytes: Map.get(reason, :free_bytes),
          min_free_bytes: Map.get(reason, :min_free_bytes),
          setting: Map.get(reason, :setting)
        })

        blocked_entry = %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: issue.state,
          worker_host: worker_host,
          workspace_path: nil,
          session_id: nil,
          blocked_at: DateTime.utc_now(),
          reason: :workspace_disk_guard,
          detail: detail,
          session_history: [
            %{
              at: DateTime.utc_now(),
              source: :system,
              event: "workspace_disk_guard.blocked",
              label: "Workspace disk guard",
              detail: detail,
              severity: :warning
            }
          ],
          session_history_total_count: 1
        }

        %{
          state
          | blocked: Map.put(state.blocked, issue.id, blocked_entry),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            claimed: MapSet.put(state.claimed, issue.id)
        }
      end

      defp format_disk_guard_reason(%{reason: :low_disk_space} = reason) do
        "low workspace disk space root=#{Map.get(reason, :root)} free_bytes=#{Map.get(reason, :free_bytes)} min_free_bytes=#{Map.get(reason, :min_free_bytes)} setting=#{Map.get(reason, :setting)}"
      end

      defp format_disk_guard_reason(reason) do
        inspect(reason)
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
            metadata,
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

        if prepared_retry.delay_type == :continuation do
          Logger.info("Scheduling continuation check issue_id=#{issue_id} issue_identifier=#{prepared_retry.identifier} in #{prepared_retry.delay_ms}ms")

          persist_event("run.continuation_scheduled", prepared_retry.identifier, %{
            issue_id: issue_id,
            delay_ms: prepared_retry.delay_ms
          })
        else
          error_suffix =
            if is_binary(prepared_retry.error) do
              " error=#{prepared_retry.error}"
            else
              ""
            end

          Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{prepared_retry.identifier} in #{prepared_retry.delay_ms}ms (attempt #{prepared_retry.attempt})#{error_suffix}")

          persist_event("run.retry_scheduled", prepared_retry.identifier, %{
            issue_id: issue_id,
            attempt: prepared_retry.attempt,
            delay_ms: prepared_retry.delay_ms,
            error: prepared_retry.error
          })
        end

        %{
          state
          | retry_attempts:
              Map.put(
                state.retry_attempts,
                issue_id,
                RetryPolicy.retry_entry(prepared_retry, timer_ref, retry_token, due_at_ms)
              ),
            claimed: MapSet.put(state.claimed, issue_id)
        }
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

      defp retry_workflow_context(_metadata) do
        current_workflow_context()
      end

      defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
           when is_reference(retry_token) do
        case RetryPolicy.pop_retry_attempt(state.retry_attempts, issue_id, retry_token) do
          {:ok, attempt, metadata, retry_attempts} ->
            {:ok, attempt, metadata, %{state | retry_attempts: retry_attempts}}

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
               Map.merge(metadata, %{
                 error: "environment failure circuit open: #{circuit.triggering_fingerprint}"
               })
             )}
        end
      end

      defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
        dispatch_settings = dispatch_policy_settings(state)
        terminal_states = Map.fetch!(dispatch_settings, :terminal_states)

        cond do
          terminal_issue_state?(issue.state, terminal_states) ->
            Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

            cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
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

      defp cleanup_issue_workspace(identifier, worker_host \\ nil)

      defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
        Workspace.remove_issue_workspaces(identifier, worker_host)
      end

      defp cleanup_issue_workspace(_identifier, _worker_host) do
        :ok
      end

      defp run_terminal_workspace_cleanup do
        case WorkflowStore.list_enabled() do
          [] ->
            run_terminal_workspace_cleanup_without_workflow()

          workflows ->
            Enum.each(workflows, &run_terminal_workspace_cleanup_for_workflow/1)
        end
      end

      defp run_terminal_workspace_cleanup_without_workflow do
        with :ok <- Config.validate!(),
             {:ok, settings} <- Config.settings(),
             {:ok, issues} <- Tracker.fetch_issues_by_states(settings.tracker.terminal_states) do
          cleanup_terminal_issue_workspaces(issues)
        else
          {:error, reason} ->
            log_terminal_workspace_cleanup_skip(reason)
        end
      end

      defp run_terminal_workspace_cleanup_for_workflow(workflow) do
        Config.with_workflow_context(workflow, fn ->
          with {:ok, settings} <- Config.settings(),
               :ok <- Config.validate_settings(settings),
               {:ok, issues} <- Tracker.fetch_issues_by_states(settings.tracker.terminal_states) do
            cleanup_terminal_issue_workspaces(issues)
          else
            {:error, reason} ->
              log_terminal_workspace_cleanup_skip(reason)
          end
        end)
      end

      defp cleanup_terminal_issue_workspaces(issues) when is_list(issues) do
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

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

      defp release_issue_claim(%State{} = state, issue_id) do
        %{
          state
          | claimed: MapSet.delete(state.claimed, issue_id),
            failure_counts: Map.delete(state.failure_counts, issue_id)
        }
      end

      defp maybe_put_runtime_value(running_entry, _key, nil) do
        running_entry
      end

      defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
        Map.put(running_entry, key, value)
      end

      defp select_worker_host(%State{} = state, preferred_worker_host) do
        DispatchPolicy.select_worker_host(state, preferred_worker_host, worker_policy_settings())
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
          if running_ref == ref do
            issue_id
          end
        end)
      end

      defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id) do
        session_id
      end

      defp running_entry_session_id(_running_entry) do
        "n/a"
      end

      defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
        "issue_id=#{issue_id} issue_identifier=#{identifier}"
      end

      defp available_slots(%State{} = state) do
        max(state.max_concurrent_agents - map_size(state.running), 0)
      end

      defp refresh_deployment_capacity(%State{} = state) do
        capacity =
          case Config.execution_mode() do
            :worker -> worker_deployment_capacity()
            :centralized -> Config.panel_max_concurrent_agents()
          end

        %{state | max_concurrent_agents: capacity}
      end

      defp worker_deployment_capacity do
        AssignmentManager.available_worker_slots()
      catch
        :exit, {:timeout, {GenServer, :call, @capacity_query_args}} ->
          Logger.warning("event=orchestrator.capacity_query_timeout execution_mode=worker timeout_ms=5000 fallback_capacity=0")

          0
      end
    end
  end
end
