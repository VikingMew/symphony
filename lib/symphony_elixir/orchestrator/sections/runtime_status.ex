# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.RuntimeStatus do
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

      defp load_operator_workflow(project) do
        case persistence().current_workflow(project) do
          nil ->
            {:error, :no_workflow}

          {:error, reason} ->
            {:error, {:workflow_lookup_failed, reason}}

          workflow ->
            with instance when is_map(instance) <- persistence().instance_workflow(),
                 {:ok, loaded} <- persistence().workflow_to_loaded(instance, workflow) do
              {:ok, loaded}
            else
              nil -> {:error, :no_instance_workflow}
              {:error, reason} -> {:error, {:workflow_lookup_failed, reason}}
            end
        end
      rescue
        error -> {:error, {:workflow_lookup_failed, error}}
      end

      defp fail_operator_task_resolution(task, reason) do
        failure_reason = operator_project_failure_reason(reason, task.project_id)

        %{
          task
          | status: :failed,
            finished_at: DateTime.utc_now(),
            failure_reason: failure_reason,
            summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
        }
      end

      defp operator_project_failure_reason(:project_required, _project_id) do
        "project required"
      end

      defp operator_project_failure_reason(:unknown_project, project_id) do
        "unknown project: #{project_id}"
      end

      defp operator_project_failure_reason(:no_workflow, project_id) do
        "no workflow for project: #{project_id}"
      end

      defp operator_project_failure_reason({:project_lookup_failed, reason}, _project_id) do
        "project lookup failed: #{inspect(reason, limit: 20, printable_limit: 1000)}"
      end

      defp operator_project_failure_reason({:workflow_lookup_failed, reason}, project_id) do
        "workflow lookup failed for project #{project_id}: #{inspect(reason, limit: 20, printable_limit: 1000)}"
      end

      defp operator_kind_from_running_entry(%RunningOperator{kind: kind})
           when kind in [:nap, :day_dreaming] do
        kind
      end

      defp operator_kind_from_running_entry(_running_entry) do
        nil
      end

      defp clear_operator_tasks(%State{} = state, status) do
        tasks =
          state.operator_tasks
          |> Enum.map(fn {kind, task} ->
            {kind,
             %{
               task
               | status: status,
                 finished_at: DateTime.utc_now(),
                 failure_reason: "force stopped"
             }}
          end)
          |> Map.new()

        %{state | operator_tasks: tasks}
      end

      defp runtime_busy?(%State{} = state) do
        Enum.any?(state.running, fn {_id, entry} -> runtime_entry_active?(entry) end)
      end

      defp runtime_entry_active?(%RunningIssue{}) do
        true
      end

      defp runtime_entry_active?(%RunningOperator{pid: pid, session_id: session_id}) do
        (is_pid(pid) and Process.alive?(pid)) or is_binary(session_id)
      end

      defp runtime_entry_active?(_entry) do
        false
      end

      defp issue_running_ids(running) when is_map(running) do
        running
        |> Enum.flat_map(fn
          {id, %RunningIssue{}} -> [id]
          {_id, %RunningOperator{}} -> []
        end)
      end

      defp reconcile_stale_operator_entries(%State{} = state) do
        Enum.reduce(state.running, state, fn {run_id, running_entry}, state_acc ->
          if stale_operator_running_entry?(running_entry) do
            reason = "operator task has no live process or Codex session"

            failed_entry =
              append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
                source: :system,
                run_id: run_id,
                kind: running_entry_kind(running_entry),
                reason: reason
              })

            persist_event(
              "operator_task.stale_failed",
              nil,
              %{kind: running_entry_kind(running_entry), run_id: run_id, reason: reason},
              running_entry.run_id
            )

            persist_run_finished(failed_entry, "failed", reason)

            state_acc
            |> Map.update!(:running, &Map.delete(&1, run_id))
            |> finish_operator_task(failed_entry, :failed, reason)
          else
            state_acc
          end
        end)
      end

      defp stale_operator_running_entry?(%RunningOperator{} = running_entry) do
        !runtime_entry_active?(running_entry)
      end

      defp stale_operator_running_entry?(_running_entry) do
        false
      end

      defp operator_task(%State{} = state, kind) do
        Map.get(state.operator_tasks || %{}, kind, %{
          kind: kind,
          project_id: nil,
          status: :idle,
          run_id: nil,
          requested_at: nil,
          queued_at: nil,
          started_at: nil,
          finished_at: nil,
          failure_reason: nil,
          summary: nil
        })
      end

      defp put_operator_task(%State{} = state, kind, task) do
        %{state | operator_tasks: Map.put(state.operator_tasks || %{}, kind, task)}
      end

      defp operator_task_reply(task, request_status) do
        task
        |> operator_task_payload()
        |> Map.put(:accepted, request_status == :accepted)
      end

      defp operator_tasks_payload(%State{} = state) do
        %{
          nap: operator_task_payload(operator_task(state, :nap)),
          day_dreaming: operator_task_payload(operator_task(state, :day_dreaming))
        }
      end

      defp operator_task_payload(task) do
        %{
          kind: to_string(task.kind),
          project_id: task.project_id,
          status: to_string(task.status),
          run_id: task.run_id,
          requested_at: iso8601_or_nil(task.requested_at),
          queued_at: iso8601_or_nil(task.queued_at),
          started_at: iso8601_or_nil(task.started_at),
          finished_at: iso8601_or_nil(task.finished_at),
          failure_reason: task.failure_reason,
          summary: task.summary
        }
      end

      defp iso8601_or_nil(%DateTime{} = value) do
        DateTime.to_iso8601(value)
      end

      defp iso8601_or_nil(_value) do
        nil
      end

      defp cancel_retry_timers(%State{retry_attempts: retry_attempts} = state) do
        Enum.each(retry_attempts, fn
          {_issue_id, %{timer_ref: timer_ref}} when is_reference(timer_ref) ->
            Process.cancel_timer(timer_ref)

          _ ->
            :ok
        end)

        %{state | retry_attempts: %{}}
      end

      defp force_stop_running_entries(%State{running: running} = state) do
        {state, results} =
          Enum.reduce(running, {state, []}, fn {issue_id, running_entry}, {state_acc, results_acc} ->
            result = rollback_running_entry(issue_id, running_entry)
            state_acc = terminate_running_issue(state_acc, issue_id, false)
            {state_acc, [result | results_acc]}
          end)

        {%{state | running: %{}, claimed: MapSet.new()}, Enum.reverse(results)}
      end

      defp rollback_running_entry(_run_id, %RunningOperator{} = running_entry) do
        kind = running_entry_kind(running_entry)
        persist_event("run.force_stopped", nil, %{run_id: running_entry.run_id, kind: kind})
        %{run_id: running_entry.run_id, kind: kind, status: "stopped", reason: "operator_task"}
      end

      defp rollback_running_entry(issue_id, %RunningIssue{} = running_entry) do
        rollback_issue_running_entry(issue_id, running_entry)
      end

      defp rollback_issue_running_entry(issue_id, running_entry) do
        transitions = Map.get(running_entry, :linear_state_transitions, [])

        result =
          transitions
          |> Enum.find(&Map.get(&1, :rollback_to_state))
          |> rollback_transition(issue_id, running_entry)

        persist_event("run.force_stopped", Map.get(running_entry, :identifier), %{
          issue_id: issue_id,
          rollback: result
        })

        result
      end

      defp rollback_transition(nil, issue_id, running_entry) do
        %{
          issue_id: issue_id,
          issue_identifier: Map.get(running_entry, :identifier),
          status: "skipped",
          reason: "no_symphony_owned_transition"
        }
      end

      defp rollback_transition(transition, issue_id, running_entry) do
        expected_state = Map.get(transition, :to_state)
        rollback_to_state = Map.get(transition, :rollback_to_state)
        identifier = Map.get(running_entry, :identifier)

        with {:ok, [%Issue{state: current_state} | _]} <-
               Tracker.fetch_issue_states_by_ids([issue_id]),
             true <- normalize_issue_state(current_state) == normalize_issue_state(expected_state),
             :ok <- Tracker.update_issue_state(issue_id, rollback_to_state) do
          %{
            issue_id: issue_id,
            issue_identifier: identifier,
            status: "rolled_back",
            from_state: expected_state,
            to_state: rollback_to_state
          }
        else
          false ->
            %{
              issue_id: issue_id,
              issue_identifier: identifier,
              status: "skipped",
              reason: "linear_state_changed",
              expected_state: expected_state
            }

          {:ok, []} ->
            %{
              issue_id: issue_id,
              issue_identifier: identifier,
              status: "skipped",
              reason: "issue_not_found"
            }

          {:error, reason} ->
            %{
              issue_id: issue_id,
              issue_identifier: identifier,
              status: "failed",
              reason: inspect(reason)
            }
        end
      end

      defp cancel_active_worker_tasks do
        AssignmentManager.cancel_current("force_stop_all")
      end

      defp handle_worker_task_started(
             %State{} = state,
             %{issue: %Issue{id: issue_id} = issue} = assignment
           ) do
        worker_host = worker_host_from_assignment(assignment)
        attempt = worker_assignment_attempt(assignment)

        running_entry = %RunningIssue{
          pid: nil,
          ref: nil,
          run_id: Map.get(assignment, :run_id),
          identifier: issue.identifier,
          issue: issue,
          project_id: Map.get(assignment, :project_id),
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
          retry_attempt: attempt,
          failure_count: Map.get(state.failure_counts, issue_id, 0),
          started_at: worker_assignment_started_at(assignment),
          session_history: initial_session_history(issue, attempt, worker_host),
          session_history_total_count: 1
        }

        %{
          state
          | running: Map.put(state.running, issue_id, running_entry),
            claimed: MapSet.put(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
      end

      defp handle_worker_task_progress(%State{} = state, issue_id, payload) do
        case worker_codex_update(payload) do
          {:ok, update} ->
            case Map.get(state.running, issue_id) do
              %RunningIssue{} = running_entry ->
                handle_codex_worker_update(state, issue_id, running_entry, update)

              _missing ->
                state
            end

          :ignore ->
            state
        end
      end

      defp handle_codex_worker_update(%State{running: running} = state, issue_id, running_entry, update) do
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        persist_codex_update(updated_running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update, running_entry.project_id)

        notify_dashboard()
        %{state | running: Map.put(running, issue_id, updated_running_entry)}
      end

      defp worker_codex_update(payload) do
        case Payload.get_any(payload, ["codex", :codex, "message", :message]) do
          %{} = message ->
            {:ok, normalize_worker_codex_update(message, payload)}

          _ ->
            worker_session_started_update(payload)
        end
      end

      defp worker_session_started_update(payload) do
        if Payload.get_any(payload, ["phase", :phase]) in [
             "codex_session_started",
             :codex_session_started
           ] do
          message = %{
            event: :session_started,
            session_id: Payload.get_any(payload, ["session_id", :session_id])
          }

          {:ok, normalize_worker_codex_update(message, payload)}
        else
          :ignore
        end
      end

      defp normalize_worker_codex_update(message, progress_payload) do
        %{
          event: normalize_worker_codex_event(Payload.get_any(message, ["event", :event])),
          timestamp:
            normalize_worker_timestamp(
              Payload.get_any(message, ["timestamp", :timestamp]),
              progress_payload
            ),
          payload: Payload.get_any(message, ["payload", :payload]),
          raw: Payload.get_any(message, ["raw", :raw]),
          session_id:
            Payload.get_any(message, ["session_id", :session_id]) ||
              Payload.get_any(progress_payload, ["session_id", :session_id]),
          codex_app_server_pid: Payload.get_any(message, ["codex_app_server_pid", :codex_app_server_pid]),
          rate_limits: Payload.get_any(message, ["rate_limits", :rate_limits, "rateLimits", :rateLimits]),
          tokens: Payload.get_any(message, ["tokens", :tokens]),
          total_token_usage: Payload.get_any(message, ["total_token_usage", :total_token_usage]),
          usage: Payload.get_any(message, ["usage", :usage])
        }
      end

      defp normalize_worker_codex_event(event) when is_atom(event) do
        event
      end

      defp normalize_worker_codex_event("approval_required") do
        :approval_required
      end

      defp normalize_worker_codex_event("malformed") do
        :malformed
      end

      defp normalize_worker_codex_event("notification") do
        :notification
      end

      defp normalize_worker_codex_event("other_message") do
        :other_message
      end

      defp normalize_worker_codex_event("session_started") do
        :session_started
      end

      defp normalize_worker_codex_event("startup_failed") do
        :startup_failed
      end

      defp normalize_worker_codex_event("turn_cancelled") do
        :turn_cancelled
      end

      defp normalize_worker_codex_event("turn_completed") do
        :turn_completed
      end

      defp normalize_worker_codex_event("turn_ended_with_error") do
        :turn_ended_with_error
      end

      defp normalize_worker_codex_event("turn_failed") do
        :turn_failed
      end

      defp normalize_worker_codex_event("turn_input_required") do
        :turn_input_required
      end

      defp normalize_worker_codex_event(event) do
        event
      end

      defp normalize_worker_timestamp(%DateTime{} = timestamp, _progress_payload) do
        timestamp
      end

      defp normalize_worker_timestamp(timestamp, _progress_payload) when is_binary(timestamp) do
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> datetime
          _error -> DateTime.utc_now()
        end
      end

      defp normalize_worker_timestamp(_timestamp, progress_payload) do
        case Payload.get_any(progress_payload, ["occurred_at", :occurred_at]) do
          %DateTime{} = occurred_at ->
            occurred_at

          occurred_at when is_binary(occurred_at) ->
            normalize_worker_timestamp(occurred_at, %{})

          _ ->
            DateTime.utc_now()
        end
      end

      defp worker_host_from_assignment(assignment) do
        Map.get(assignment, :worker_name) || Map.get(assignment, :worker_id)
      end

      defp worker_assignment_attempt(%{correlation: correlation}) when is_map(correlation) do
        RetryPolicy.normalize_attempt(Map.get(correlation, "run_attempt"))
      end

      defp worker_assignment_started_at(assignment) do
        Map.get(assignment, :started_at) || DateTime.utc_now()
      end

      defp integrate_codex_update(running_entry, %{event: _event, timestamp: _timestamp} = update) do
        SessionHistory.integrate_codex_update(running_entry, update)
      end

      defp initial_session_history(%Issue{} = issue, attempt, worker_host) do
        SessionHistory.initial(issue, attempt, worker_host)
      end

      defp append_system_history(running_entry, update)
           when is_map(running_entry) and is_map(update) do
        SessionHistory.append_system(running_entry, update)
      end

      defp append_session_history(running_entry, event, label, metadata) when is_map(running_entry) do
        SessionHistory.append(running_entry, event, label, metadata)
      end

      defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
        if is_reference(state.tick_timer_ref) do
          Process.cancel_timer(state.tick_timer_ref)
        end

        tick_token = make_ref()
        timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

        %{
          state
          | tick_timer_ref: timer_ref,
            tick_token: tick_token,
            next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
        }
      end

      defp schedule_poll_cycle_start do
        :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
        :ok
      end

      defp next_poll_in_ms(nil, _now_ms) do
        nil
      end

      defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
        max(0, next_poll_due_at_ms - now_ms)
      end

      defp pop_running_entry(state, issue_id) do
        {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
      end

      defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
        runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

        codex_totals =
          apply_token_delta(
            state.codex_totals,
            %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: runtime_seconds
            }
          )

        %{state | codex_totals: codex_totals}
      end

      defp record_session_completion_totals(state, _running_entry) do
        state
      end

      defp snapshot_codex_totals(%State{} = state, %DateTime{} = now) do
        active_seconds =
          Enum.reduce(state.running, 0, fn {_id, running_entry}, seconds ->
            seconds + running_seconds(Map.get(running_entry, :started_at), now)
          end)

        apply_token_delta(state.codex_totals, %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: active_seconds
        })
      end

      defp refresh_runtime_config(%State{} = state) do
        case runtime_config() do
          {:ok, config} ->
            %{
              state
              | poll_interval_ms: config.polling.interval_ms,
                max_concurrent_agents: Config.panel_max_concurrent_agents(),
                last_config_error: nil
            }

          {:error, reason} ->
            state
            |> log_config_error_once(reason)
            |> Map.merge(%{
              listening_mode: :not_listening,
              poll_check_in_progress: false,
              max_concurrent_agents: 0
            })
        end
      end

      defp listening?(%State{listening_mode: :not_listening}) do
        false
      end

      defp listening?(%State{}) do
        true
      end

      defp listening_mode_string(%State{listening_mode: mode}) when is_atom(mode) do
        Atom.to_string(mode)
      end

      defp listening_mode_atom(%State{listening_mode: mode}) do
        mode
      end

      defp runtime_config do
        case WorkflowStore.list_enabled() do
          [] ->
            Config.settings()

          workflows ->
            aggregate_runtime_limits(workflows)
        end
      end

      defp aggregate_runtime_limits(workflows) do
        with {:ok, settings} <- parse_runtime_settings(workflows) do
          {:ok,
           %{
             polling: %{interval_ms: settings |> Enum.map(& &1.polling.interval_ms) |> Enum.min()},
             agent: %{}
           }}
        end
      end

      defp parse_runtime_settings(workflows) do
        Enum.reduce_while(workflows, {:ok, []}, &parse_runtime_setting/2)
      end

      defp parse_runtime_setting(%{config: config}, {:ok, settings}) do
        with {:ok, parsed} <- Schema.parse(config),
             :ok <- Config.validate_settings(parsed) do
          {:cont, {:ok, [parsed | settings]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end

      defp agent_runner do
        Application.get_env(:symphony_elixir, :agent_runner_module, AgentRunner)
      end

      defp environment_failure_circuit_allows_dispatch do
        case EnvironmentFailureCircuit.check() do
          :allow -> :allow
          {:block, circuit} -> {:environment_failure_circuit_open, circuit}
        end
      end

      defp rate_limit_gate_allows_dispatch(%State{} = state) do
        case check_rate_limit_gate(state) do
          :allow -> :allow
          {:block, details} -> {:block, details}
        end
      end

      defp refresh_rate_limit_gate(%State{} = state) do
        case check_rate_limit_gate(state) do
          :allow ->
            %{
              state
              | rate_limit_gate: rate_limit_gate_allow_snapshot(),
                rate_limit_gate_event_fingerprint: nil
            }

          {:block, details} ->
            apply_rate_limit_gate_block(state, details)
        end
      end

      defp apply_rate_limit_gate_block(%State{} = state, details) when is_map(details) do
        fingerprint = rate_limit_gate_fingerprint(details)

        if state.rate_limit_gate_event_fingerprint != fingerprint do
          persist_event(
            "codex.rate_limit_gate.blocked",
            nil,
            Map.put(details, :message, rate_limit_gate_message(details))
          )
        end

        %{state | rate_limit_gate: details, rate_limit_gate_event_fingerprint: fingerprint}
      end

      defp rate_limit_gate_blocked?(%State{} = state) do
        case check_rate_limit_gate(state) do
          {:block, _details} -> true
          _ -> false
        end
      end

      defp rate_limit_gate_snapshot do
        %{status: :project_scoped, reason: :project_scoped}
      end

      defp check_rate_limit_gate(%State{} = state) do
        RateLimitGate.check(state.codex_rate_limits, Config.settings!())
      rescue
        error ->
          reason = Exception.message(error)

          Logger.error("Rate-limit gate evaluation failed action=block_dispatch status=blocked reason=#{inspect(reason)}")

          {:block, %{status: :blocked, reason: :evaluation_error, error: reason}}
      end

      defp rate_limit_gate_allow_snapshot do
        %{
          status: :allow,
          reason: :available
        }
      end

      defp rate_limit_gate_fingerprint(details) do
        [
          Map.get(details, :window),
          Map.get(details, :window_duration_mins),
          Map.get(details, :threshold_percent),
          Map.get(details, :resets_at),
          Map.get(details, :resume_after)
        ]
      end

      defp rate_limit_gate_message(%{reason: :evaluation_error, error: error}) do
        "Codex session start paused because rate-limit gate evaluation failed: #{error}"
      end

      defp rate_limit_gate_message(details) do
        "Codex session start paused by #{Map.get(details, :window)} rate-limit headroom: remaining=#{Map.get(details, :remaining_percent)} threshold=#{Map.get(details, :threshold_percent)} resume_after=#{Map.get(details, :resume_after) || "n/a"}"
      end

      defp config_error_payload(nil) do
        nil
      end

      defp config_error_payload(reason) do
        %{
          reason: inspect(reason),
          message: config_validation_error_message(reason),
          unavailable: database_read_error?(reason)
        }
      end

      defp database_read_error?(:repo_unavailable) do
        true
      end

      defp database_read_error?({:query_failed, _reason}) do
        true
      end

      defp database_read_error?(_reason) do
        false
      end

      defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
        DispatchPolicy.dispatch_slots_available?(issue, state, dispatch_policy_settings(state))
      end

      defp apply_codex_token_delta(
             %{codex_totals: codex_totals} = state,
             %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
           )
           when is_integer(input) and is_integer(output) and is_integer(total) do
        %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
      end

      defp apply_codex_token_delta(state, _token_delta) do
        state
      end

      defp apply_codex_rate_limits(%State{} = state, update, project_id) when is_map(update) do
        case Update.rate_limits(update) do
          %{} = rate_limits ->
            state = %{
              state
              | codex_rate_limits: rate_limits,
                codex_rate_limit_observation: %{status: :parsed, at: DateTime.utc_now()}
            }

            refresh_project_rate_limit_gate(state, project_id)

          _ ->
            if Update.rate_limit_update_event?(update) do
              %{
                state
                | codex_rate_limit_observation: %{
                    status: :unrecognized,
                    at: DateTime.utc_now(),
                    event: Map.get(update, :event),
                    debug_payload: Update.rate_limit_debug_payload(update)
                  }
              }
            else
              state
            end
        end
      end

      defp refresh_project_rate_limit_gate(state, project_id) do
        {:ok, workflow} = WorkflowStore.for_project(project_id)
        Config.with_workflow_context(workflow, fn -> refresh_rate_limit_gate(state) end)
      end

      defp apply_token_delta(codex_totals, token_delta) do
        input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
        output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
        total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

        seconds_running =
          Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

        %{
          input_tokens: max(0, input_tokens),
          output_tokens: max(0, output_tokens),
          total_tokens: max(0, total_tokens),
          seconds_running: max(0, seconds_running)
        }
      end

      defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
        max(0, DateTime.diff(now, started_at, :second))
      end

      defp running_seconds(_started_at, _now) do
        0
      end

      defp running_entry_state(%{issue: %{state: state}}) do
        state
      end

      defp running_entry_state(metadata) do
        Map.get(metadata, :state, "running")
      end

      defp running_entry_kind(%RunningIssue{kind: kind}) do
        Atom.to_string(kind)
      end

      defp running_entry_kind(%RunningOperator{kind: kind}) do
        Atom.to_string(kind)
      end
    end
  end
end
