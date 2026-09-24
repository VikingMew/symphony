# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Orchestrator.Sections.Persistence do
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

      defp persist_polled_issues(issues) do
        if persistence_enabled?() do
          case current_workflow_context() do
            {:ok, workflow} ->
              project_id = Map.get(workflow, :project_id)
              Enum.each(issues, &persist_polled_issue(&1, project_id))

            {:error, reason} ->
              Logger.warning("Skipping polled issue persistence; workflow context unavailable: #{inspect(reason)}")
          end
        end

        :ok
      end

      defp persist_polled_issue(%Issue{} = issue, project_id) do
        case persist_write(:upsert_polled_issue, persistence_context(issue), fn ->
               persistence().upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id))
             end) do
          {:ok, _issue_record} -> :ok
          {:degraded, :repo_unavailable} -> :ok
        end
      end

      defp persist_polled_issue(_issue, _project_id) do
        :ok
      end

      defp current_workflow_context do
        Config.current_workflow()
      end

      defp current_workflow_record(%{project_id: project_id}) when is_binary(project_id) do
        case Enum.find(persistence().list_projects(), &(&1.id == project_id)) do
          nil -> nil
          project -> persistence().current_workflow(project)
        end
      end

      defp current_workflow_record(_workflow) do
        persistence().current_workflow()
      end

      defp persist_run_started_event(issue, run, worker_host) do
        case persist_event(Events.run_started_event(issue, run, worker_host)) do
          :ok -> {:ok, run}
          {:degraded, :repo_unavailable} -> {:ok, run}
        end
      end

      defp persist_operator_started_event(task, run) do
        case persist_event("operator_task.started", nil, %{kind: to_string(task.kind), run_id: run.id}) do
          :ok -> {:ok, run}
          {:degraded, :repo_unavailable} -> {:ok, run}
        end
      end

      defp persist_run_started(%Issue{} = issue, attempt, worker_host) do
        if persistence_enabled?() do
          run_started_persist(issue, attempt, worker_host)
        else
          {:ok, nil}
        end
      rescue
        error ->
          context = persistence_context(issue)
          log_persistence_failure(:start_run, "fail_task", context, error)
          {:error, {:start_run, {:exception, error}}}
      end

      defp run_started_persist(issue, attempt, worker_host) do
        case current_workflow_context() do
          {:ok, workflow} ->
            project_id = Map.get(workflow, :project_id)
            context = persistence_context(issue)

            with {:ok, issue_record} <- persist_upsert_issue(context, issue, project_id),
                 workflow_record = current_workflow_record(workflow),
                 run_attrs =
                   issue
                   |> Events.run_attrs(workflow_record, "centralized", attempt)
                   |> Map.put(:issue_id, issue_record.id)
                   |> Map.put_new(:project_id, project_id),
                 {:ok, run} <- persist_create_run(context, run_attrs) do
              persist_run_started_event(issue, run, worker_host)
            end

          {:error, reason} ->
            {:error, {:workflow_context, reason}}
        end
      end

      defp persist_upsert_issue(context, issue, project_id) do
        required_persistence_write(:upsert_issue, context, fn -> upsert_issue!(issue, project_id) end)
      end

      defp persist_create_run(context, run_attrs) do
        required_persistence_write(:create_run, context, fn -> create_run!(run_attrs) end)
      end

      defp upsert_issue!(issue, project_id) do
        persistence().upsert_issue(Map.put(Events.issue_attrs(issue), :project_id, project_id))
      end

      defp create_run!(run_attrs) do
        persistence().create_run(run_attrs)
      end

      defp persist_operator_run_started(task) do
        if persistence_enabled?() do
          operator_run_started_persist(task)
        else
          {:ok, nil}
        end
      rescue
        error ->
          context = %{issue_id: nil, issue_identifier: nil, run_id: task.run_id, session_id: nil}
          log_persistence_failure(:start_operator_run, "fail_task", context, error)
          {:error, {:start_operator_run, {:exception, error}}}
      end

      defp operator_run_started_persist(task) do
        case current_workflow_context() do
          {:ok, workflow} ->
            workflow_record = current_workflow_record(workflow)
            context = %{issue_id: nil, issue_identifier: nil, run_id: task.run_id, session_id: nil}

            with {:ok, run} <- persist_create_operator_run(context, task, workflow_record) do
              persist_operator_started_event(task, run)
            end

          {:error, reason} ->
            {:error, {:workflow_context, reason}}
        end
      end

      defp persist_create_operator_run(context, task, workflow_record) do
        required_persistence_write(:create_operator_run, context, fn ->
          create_operator_run!(task, workflow_record)
        end)
      end

      defp create_operator_run!(task, _workflow_record) do
        persistence().create_run(%{
          kind: to_string(task.kind),
          profile: to_string(task.kind),
          label: operator_task_label(task.kind),
          project_id: task.project_id,
          status: "running",
          execution_mode: "centralized",
          attempt: 0,
          started_at: task.started_at
        })
      end

      defp persist_run_finished(running_entry, status, failure_reason) when is_map(running_entry) do
        if persistence_enabled?() do
          run_id = Map.get(running_entry, :run_id)
          context = persistence_context(running_entry)

          case RunLifecycle.finish_run(persistence(), run_id, status, failure_reason) do
            {:ok, _run} ->
              persist_event(Events.run_finished_event(running_entry, status, failure_reason))

            :noop ->
              :ok

            {:error, :repo_unavailable} ->
              log_persistence_degraded(:finish_run, context)
              {:degraded, :repo_unavailable}

            {:error, reason} ->
              propagate_persistence_failure(:finish_run, context, reason)
          end
        else
          :ok
        end
      end

      defp persist_workspace_update(running_entry) when is_map(running_entry) do
        if persistence_enabled?() do
          record_workspace_update(running_entry)
        else
          :ok
        end
      end

      defp record_workspace_update(running_entry) do
        case Events.workspace_attrs(running_entry) do
          %{} = attrs -> write_workspace_record(running_entry, attrs)
          _ -> :ok
        end
      end

      defp write_workspace_record(running_entry, attrs) do
        case persist_write(:record_workspace, persistence_context(running_entry), fn ->
               persistence().record_workspace(attrs)
             end) do
          {:ok, _workspace} ->
            persist_event(Events.workspace_created_event(running_entry))

          {:degraded, :repo_unavailable} = degraded ->
            degraded
        end
      end

      defp persist_codex_update(running_entry, update)
           when is_map(running_entry) and is_map(update) do
        persist_event(
          "codex.update",
          Map.get(running_entry, :identifier),
          Update.event_payload(update),
          Map.get(running_entry, :run_id)
        )
      end

      defp persist_event(event_type, issue_identifier, payload, run_id \\ nil) do
        persist_event(Events.event_attrs(event_type, issue_identifier, payload, run_id))
      end

      defp persist_event(%{} = attrs) do
        if persistence_enabled?() do
          record_event(attrs)
        else
          :ok
        end
      end

      defp record_event(attrs) do
        case persist_write(:record_event, persistence_context(attrs), fn ->
               persistence().record_event(attrs)
             end) do
          {:ok, _event} -> :ok
          {:degraded, :repo_unavailable} = degraded -> degraded
        end
      end

      defp required_persistence_write(operation, context, fun) when is_function(fun, 0) do
        result =
          try do
            fun.()
          rescue
            error -> {:raised, error, __STACKTRACE__}
          end

        case result do
          {:ok, record} ->
            {:ok, record}

          {:error, reason} ->
            log_persistence_failure(operation, "fail_task", context, reason)
            {:error, {operation, reason}}

          {:raised, error, stacktrace} ->
            log_persistence_failure(operation, "fail_task", context, error)
            {:error, {operation, {:exception, error, stacktrace}}}

          other ->
            reason = {:unexpected_result, other}
            log_persistence_failure(operation, "fail_task", context, reason)
            {:error, {operation, reason}}
        end
      end

      defp persist_write(operation, context, fun) when is_function(fun, 0) do
        result =
          try do
            fun.()
          rescue
            error ->
              log_persistence_failure(operation, "propagate", context, error)
              reraise error, __STACKTRACE__
          end

        case result do
          {:ok, record} ->
            {:ok, record}

          {:error, :repo_unavailable} ->
            log_persistence_degraded(operation, context)
            {:degraded, :repo_unavailable}

          {:error, reason} ->
            propagate_persistence_failure(operation, context, reason)

          other ->
            propagate_persistence_failure(operation, context, {:unexpected_result, other})
        end
      end

      defp propagate_persistence_failure(operation, context, reason) do
        log_persistence_failure(operation, "propagate", context, reason)
        :erlang.error({:orchestrator_persistence_failure, operation, reason})
      end

      defp log_persistence_degraded(operation, context) do
        Logger.warning("Orchestrator persistence degraded operation=#{operation} action=continue_degraded #{persistence_log_context(context)} reason=repo_unavailable")
      end

      defp log_persistence_failure(operation, action, context, reason) do
        Logger.error("Orchestrator persistence failed operation=#{operation} action=#{action} #{persistence_log_context(context)} reason=#{inspect(reason, limit: 20, printable_limit: 1000)}")
      end

      defp persistence_log_context(context) do
        "issue_id=#{log_field(Map.get(context, :issue_id))} issue_identifier=#{log_field(Map.get(context, :issue_identifier))} session_id=#{log_field(Map.get(context, :session_id))} run_id=#{log_field(Map.get(context, :run_id))}"
      end

      defp persistence_context(%Issue{} = issue) do
        %{issue_id: issue.id, issue_identifier: issue.identifier, session_id: nil, run_id: nil}
      end

      defp persistence_context(%{event_type: _event_type} = attrs) do
        payload = Map.get(attrs, :payload, %{})

        %{
          issue_id: Payload.get_any(payload, [:issue_id, "issue_id"], nil),
          issue_identifier: Map.get(attrs, :issue_identifier),
          session_id: Payload.get_any(payload, [:session_id, "session_id"], nil),
          run_id: Map.get(attrs, :run_id)
        }
      end

      defp persistence_context(running_entry) when is_map(running_entry) do
        issue = Map.get(running_entry, :issue)

        %{
          issue_id:
            Map.get(running_entry, :issue_id) ||
              if is_map(issue) do
                Map.get(issue, :id)
              end,
          issue_identifier: Map.get(running_entry, :identifier),
          session_id: Map.get(running_entry, :session_id),
          run_id: Map.get(running_entry, :run_id)
        }
      end

      defp log_field(nil) do
        "n/a"
      end

      defp log_field(value) do
        inspect(value, limit: 5, printable_limit: 200)
      end

      defp persistence do
        PersistenceProvider.module()
      end

      defp persistence_enabled? do
        Process.whereis(__MODULE__) == self()
      end
    end
  end
end
