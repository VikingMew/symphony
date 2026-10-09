# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Completion do
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
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator.DispatchPolicy
      alias SymphonyElixir.Orchestrator.Events
      alias SymphonyElixir.Orchestrator.InputBlocker
      alias SymphonyElixir.Orchestrator.RetryPolicy
      alias SymphonyElixir.Orchestrator.{RunningIssue, RunningOperator, State}
      alias SymphonyElixir.Orchestrator.SessionHistory
      alias SymphonyElixir.Worker.AssignmentManager
      alias SymphonyElixir.Workspace.{Remote, SourcePreparation}

      defp persist_and_block_issue(state, issue_id, running_entry, reason, evidence, references) do
        case BlockingDecision.decide(
               running_entry.identifier,
               reason,
               evidence,
               running_entry.run_id,
               running_entry.issue.state,
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
            if(delivery_transition_completed?(delivery),
              do: "Blocked",
              else: running_entry.issue.state
            ),
          run_id: running_entry.run_id,
          blocked_at: decision["decided_at"],
          reason: decision["reason"],
          detail: decision["evidence"],
          worker_host: running_entry.worker_host,
          workspace_path: running_entry.workspace_path,
          session_id: running_entry.session_id,
          project_id: running_entry.project_id,
          blocking_decision: blocking_decision_projection(decision),
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

      defp blocking_delivery_workflow(_running_entry), do: {:error, :missing_project_context}

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

      defp log_blocking_delivery_errors(issue_id, identifier, {:error, reason}) do
        Logger.error("Blocking decision delivery failed issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")
      end

      defp delivery_transition_completed?({:ok, %{transition: :ok}}), do: true
      defp delivery_transition_completed?(_delivery), do: false

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

        persist_run_finished(running_entry, "completed", :completed)
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
        run_kind = running_entry_kind(running_entry)

        Logger.warning("Operator task failed run_id=#{run_id} kind=#{run_kind} session_id=#{session_id} #{summary}")

        running_entry =
          append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
            source: :system,
            run_id: run_id,
            kind: run_kind,
            reason: summary
          })

        failure =
          RunFailure.classify({:operator_domain_failure, %{reason: reason, detail: summary, run_kind: run_kind}})

        persist_run_finished(running_entry, "failed", failure)
        finish_operator_task(state, running_entry, :failed, summary)
      end

      defp handle_operator_down_reason(state, run_id, running_entry, :normal, session_id) do
        Logger.info("Operator task completed run_id=#{run_id} kind=#{running_entry_kind(running_entry)} session_id=#{session_id}")

        persist_run_finished(running_entry, "completed", :completed)
        finish_operator_task(state, running_entry, :completed, nil)
      end

      defp handle_operator_down_reason(state, run_id, running_entry, reason, session_id) do
        summary = "operator task crashed: #{inspect(reason, limit: 20, printable_limit: 1_000)}"
        run_kind = running_entry_kind(running_entry)

        Logger.warning("Operator task crashed run_id=#{run_id} kind=#{run_kind} session_id=#{session_id} #{summary}")

        running_entry =
          append_session_history(running_entry, :operator_task_failed, "Operator task failed", %{
            source: :system,
            run_id: run_id,
            kind: run_kind,
            reason: summary
          })

        failure =
          RunFailure.classify({:worker_process_termination, %{reason: reason, phase: "operator", run_kind: run_kind}})

        persist_run_finished(running_entry, "failed", failure)
        finish_operator_task(state, running_entry, :failed, summary)
      end

      defp handle_agent_domain_failure(state, issue_id, running_entry, reason, session_id) do
        summary = agent_failure_summary(reason)
        Logger.warning("Agent task failed for issue_id=#{issue_id} session_id=#{session_id} #{summary}")

        failure = RunFailure.classify({:agent_domain_failure, %{reason: reason, detail: summary}})

        fail_or_retry(state, issue_id, running_entry, summary, :failure_retries_exhausted, reason, failure: failure)
        |> tap(fn _state -> persist_run_finished(running_entry, "failed", failure) end)
      end

      defp fail_or_retry(state, issue_id, running_entry, summary, exhausted_reason, detail, opts) do
        case retry_settings(%{project_id: Map.get(running_entry, :project_id), identifier: running_entry.identifier}) do
          {:ok, settings} ->
            do_fail_or_retry(state, issue_id, running_entry, summary, exhausted_reason, detail, settings, opts)

          {:error, reason} ->
            Logger.error("Run failure cannot be retried; workflow context unavailable issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} reason=#{inspect(reason)}")
            complete_issue(state, issue_id)
        end
      end

      defp do_fail_or_retry(state, issue_id, running_entry, summary, exhausted_reason, detail, settings, opts) do
        failure = Keyword.fetch!(opts, :failure)

        if Keyword.get(opts, :record_environment_failure, true) do
          record_environment_failure(issue_id, running_entry, failure)
        end

        decision =
          RetryPolicy.failure_decision(
            Map.get(state.failure_counts, issue_id, 0),
            settings.agent.max_failure_retries
          )

        failure_count = elem(decision, 1)
        state = %{state | failure_counts: Map.put(state.failure_counts, issue_id, failure_count)}

        if match?({:exhausted, _}, decision) do
          exhausted_failure =
            RunFailure.classify(
              {:failure_retries_exhausted,
               %{
                 failure_attempt: failure_count,
                 reason: exhausted_reason,
                 cause: RunFailure.reason(failure),
                 cause_evidence: RunFailure.evidence(failure),
                 summary: summary,
                 detail: detail
               }}
            )

          persist_and_block_issue(
            state,
            issue_id,
            running_entry,
            RunFailure.reason(exhausted_failure),
            RunFailure.evidence(exhausted_failure),
            exhausted_references(running_entry, failure_count)
          )
        else
          schedule_issue_retry(
            state,
            issue_id,
            RetryPolicy.next_retry_attempt_from_running(running_entry),
            %{
              identifier: running_entry.identifier,
              error: RunFailure.reason(failure),
              failure_evidence: RunFailure.evidence(failure),
              project_id: Map.get(running_entry, :project_id),
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path),
              workspace_authority: running_entry.admission.workspace_authority,
              failure_count: failure_count
            }
          )
        end
      end

      defp exhausted_references(running_entry, failure_count) do
        running_entry
        |> run_references()
        |> Map.put(:failure_attempt, failure_count)
        |> Map.put(:session_id, running_entry.session_id)
      end

      defp record_environment_failure(issue_id, running_entry, %RunFailure{} = failure) do
        circuit =
          EnvironmentFailureCircuit.record_failure(
            Map.fetch!(running_entry, :identifier),
            RunFailure.reason(failure),
            %{issue_id: issue_id, run_id: Map.get(running_entry, :run_id)}
          )

        if circuit.alert do
          persist_event(EnvironmentFailureCircuit.alert_event_attrs(circuit, Map.get(running_entry, :project_id)))
        end

        circuit
      end

      defp clear_failure_count(state, issue_id),
        do: %{state | failure_counts: Map.delete(state.failure_counts, issue_id)}
    end
  end
end
