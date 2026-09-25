# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Completion do
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

      defp log_blocking_delivery_errors(issue_id, identifier, {:error, reason}) do
        Logger.error("Blocking decision delivery failed issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")
      end

      defp delivery_transition_completed?({:ok, %{transition: :ok}}) do
        true
      end

      defp delivery_transition_completed?(_delivery) do
        false
      end

      defp run_references(running_entry) do
        %{worker_host: running_entry.worker_host, workspace_path: running_entry.workspace_path}
      end

      defp cancel_issue_retry(state, issue_id) do
        case Map.get(state.retry_attempts, issue_id) do
          %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
          _ -> :ok
        end

        %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
      end

      defp handle_operator_down_reason(
             state,
             run_id,
             %{agent_result: :ok} = running_entry,
             :normal,
             session_id
           ) do
        Logger.info("Operator task completed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id}")

        running_entry =
          append_session_history(
            running_entry,
            :operator_task_completed,
            "Operator task completed",
            %{
              source: :system,
              run_id: run_id,
              kind: running_entry_kind(running_entry)
            }
          )

        persist_run_finished(running_entry, "completed", nil)
        finish_operator_task(state, running_entry, :completed, nil)
      end

      defp handle_operator_down_reason(
             state,
             run_id,
             %{agent_result: {:error, reason}} = running_entry,
             :normal,
             session_id
           ) do
        summary = agent_failure_summary(reason)

        Logger.warning("Operator task failed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id} #{summary}")

        running_entry =
          append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
            source: :system,
            run_id: run_id,
            kind: running_entry_kind(running_entry),
            reason: summary
          })

        persist_run_finished(running_entry, "failed", summary)
        finish_operator_task(state, running_entry, :failed, summary)
      end

      defp handle_operator_down_reason(state, run_id, running_entry, :normal, session_id) do
        Logger.info("Operator task completed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id}")

        persist_run_finished(running_entry, "completed", nil)
        finish_operator_task(state, running_entry, :completed, nil)
      end

      defp handle_operator_down_reason(state, run_id, running_entry, reason, session_id) do
        summary = "operator task crashed: #{inspect(reason, limit: 20, printable_limit: 1000)}"

        Logger.warning("Operator task crashed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id} #{summary}")

        running_entry =
          append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
            source: :system,
            run_id: run_id,
            kind: running_entry_kind(running_entry),
            reason: summary
          })

        persist_run_finished(running_entry, "failed", summary)
        finish_operator_task(state, running_entry, :failed, summary)
      end

      defp handle_agent_domain_failure(state, issue_id, running_entry, reason, session_id) do
        summary = agent_failure_summary(reason)
        Logger.warning("Agent task failed for issue_id=#{issue_id} session_id=#{session_id} #{summary}")

        fail_or_retry(state, issue_id, running_entry, summary, :failure_retries_exhausted, reason)
        |> tap(fn _state -> persist_run_finished(running_entry, "failed", summary) end)
      end

      defp fail_or_retry(state, issue_id, running_entry, summary, exhausted_reason, detail, opts \\ []) do
        case retry_settings(%{
               project_id: Map.get(running_entry, :project_id),
               identifier: running_entry.identifier
             }) do
          {:ok, settings} ->
            do_fail_or_retry(
              state,
              issue_id,
              running_entry,
              summary,
              exhausted_reason,
              detail,
              settings,
              opts
            )

          {:error, reason} ->
            Logger.error("Run failure cannot be retried; workflow context unavailable issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} reason=#{inspect(reason)}")

            complete_issue(state, issue_id)
        end
      end

      defp do_fail_or_retry(
             state,
             issue_id,
             running_entry,
             summary,
             exhausted_reason,
             detail,
             settings,
             opts
           ) do
        if Keyword.get(opts, :record_environment_failure, true) do
          record_environment_failure(issue_id, running_entry, detail)
        end

        decision =
          RetryPolicy.failure_decision(
            Map.get(state.failure_counts, issue_id, 0),
            settings.agent.max_failure_retries
          )

        failure_count = elem(decision, 1)
        state = %{state | failure_counts: Map.put(state.failure_counts, issue_id, failure_count)}

        if match?({:exhausted, _}, decision) do
          references =
            run_references(running_entry)
            |> Map.put(:failure_attempt, failure_count)
            |> Map.put(:session_id, running_entry.session_id)

          persist_and_block_issue(
            state,
            issue_id,
            running_entry,
            exhausted_reason,
            %{summary: summary, detail: detail, failure_attempt: failure_count},
            references
          )
        else
          schedule_issue_retry(
            state,
            issue_id,
            RetryPolicy.next_retry_attempt_from_running(running_entry),
            %{
              identifier: running_entry.identifier,
              error: summary,
              project_id: Map.get(running_entry, :project_id),
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path),
              failure_count: failure_count
            }
          )
        end
      end

      defp record_environment_failure(issue_id, running_entry, reason) do
        circuit =
          EnvironmentFailureCircuit.record_failure(
            Map.fetch!(running_entry, :identifier),
            reason,
            %{issue_id: issue_id, run_id: Map.get(running_entry, :run_id)}
          )

        if circuit.alert do
          persist_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, Map.get(running_entry, :project_id)))
        end

        circuit
      end

      defp clear_failure_count(state, issue_id) do
        %{state | failure_counts: Map.delete(state.failure_counts, issue_id)}
      end

      defp block_issue_for_input(state, issue_id, running_entry, outcome, session_id) do
        summary = InputBlocker.summary(outcome)

        Logger.warning("Agent task blocked for issue_id=#{issue_id} session_id=#{session_id} #{summary}; waiting for operator input")

        updated_running_entry =
          append_session_history(
            running_entry,
            :blocked,
            "Agent blocked",
            %{message: outcome.detail, reason: outcome.reason, source: :agent}
          )

        persist_run_finished(updated_running_entry, "blocked", summary)

        references =
          run_references(updated_running_entry)
          |> Map.merge(Map.get(outcome, :references, %{}))
          |> Map.put(:session_id, session_id)

        persist_and_block_issue(
          state,
          issue_id,
          updated_running_entry,
          outcome.reason,
          outcome.detail,
          references
        )
      end

      defp agent_exit_summary(:normal, %{agent_result: :success}) do
        "completed"
      end

      defp agent_exit_summary(:normal, %{agent_result: {:failed, reason}}) do
        "failed #{agent_failure_summary(reason)}"
      end

      defp agent_exit_summary(:normal, %{agent_result: {:blocked, outcome}}) do
        InputBlocker.summary(outcome)
      end

      defp agent_exit_summary(:normal, _running_entry) do
        "completed"
      end

      defp agent_exit_summary(reason, _running_entry) do
        "crashed #{inspect(reason, limit: 20, printable_limit: 1000)}"
      end

      defp agent_failure_summary({:workspace_hook_timeout, hook_name, timeout_ms, details}) do
        elapsed_ms =
          if is_map(details) do
            Map.get(details, :elapsed_ms)
          else
            nil
          end

        output =
          if is_map(details) do
            Map.get(details, :recent_output, "")
          else
            ""
          end

        setting = timeout_setting_hint(hook_name)

        "class=workspace_hook_timeout hook=#{hook_name} timeout_ms=#{timeout_ms} elapsed_ms=#{elapsed_ms} setting=#{setting} output=#{compact_log_output(output)}"
      end

      defp agent_failure_summary(reason) do
        "class=agent_domain_failure reason=#{compact_log_output(inspect(reason, limit: 20, printable_limit: 1000))}"
      end

      defp timeout_setting_hint("project_bootstrap") do
        "Settings / Workflow / Bootstrap / Initialize timeout ms"
      end

      defp timeout_setting_hint(_hook_name) do
        "Settings / Workflow / Lifecycle Hooks / Hook timeout ms"
      end

      defp compact_log_output(output) do
        output
        |> to_string()
        |> String.replace("\r", "\n")
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-8)
        |> Enum.join(" | ")
        |> String.slice(0, 1000)
      end
    end
  end
end
