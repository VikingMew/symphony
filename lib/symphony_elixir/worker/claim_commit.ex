defmodule SymphonyElixir.Worker.ClaimCommit do
  @moduledoc "Commits one prepared claim using stable run, assignment, and event identities."
  alias SymphonyElixir.{Config, PromptBuilder, RunFailure}

  alias SymphonyElixir.AgentRunner.Policy
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.Worker.ClaimStage

  @type operation :: {:activate, map()} | {:abort, map(), term()}

  @spec run(map(), operation(), map()) :: tuple()
  def run(dependencies, operation, context) do
    prepared = elem(operation, 1)
    context = Map.put(context, :issue, prepared.issue)
    Config.with_workflow_context(prepared.workflow, fn -> execute(dependencies, operation, context) end)
  end

  defp execute(deps, {:activate, prepared} = operation, context) do
    case ClaimStage.measure(context, :run_lookup, fn -> deps.persistence.get_run(prepared.run_id) end) do
      nil -> create_run(deps, prepared, context)
      %{status: "running"} = run -> recover_activation(deps, prepared, run, context)
      %{} -> {:error, :claim_run_not_running}
      {:error, reason} -> {:retry, operation, {:run_lookup, reason}}
    end
  end

  defp execute(deps, {:abort, prepared, reason} = operation, context) do
    failure = RunFailure.classify({:claim_transition_failure, reason})

    result =
      ClaimStage.measure(context, :run_failure, fn ->
        deps.persistence.finish_run(prepared.run_id, "failed", failure)
      end)

    case result do
      {:ok, _run} -> {:error, reason}
      {:error, write_error} -> {:retry, operation, {:run_failure, write_error}}
    end
  end

  defp create_run(deps, prepared, context) do
    now = deps.now.()
    issue = prepared.issue
    issue_attrs = Map.put(Events.issue_attrs(issue), :project_id, prepared.workflow.project_id)

    run_attrs =
      Events.run_attrs(issue, prepared.admission, nil)
      |> Map.merge(%{id: prepared.run_id, project_id: prepared.workflow.project_id, status: "running", started_at: now})

    opts = [manual_rerun?: same_issue_state?(issue.state, "Todo"), orphan_cutoff: DateTime.add(now, -deps.persistence.worker_lease_duration_seconds(), :second), now: now]

    result =
      ClaimStage.measure(context, :run_admission, fn ->
        deps.persistence.admit_issue_run(issue_attrs, run_attrs, opts)
      end)

    case result do
      {:ok, %{run: run}} ->
        activate(deps, prepared, run, issue, context)

      {:error, {:active_run, run_id}} when run_id == prepared.run_id ->
        {:retry, {:activate, prepared}, :run_commit_confirmation_pending}

      {:error, {:active_run, run_id}} ->
        {:ok, nil,
         %{
           reason: :active_run,
           listening_mode: context.listening_mode,
           capacity: 0,
           run_id: run_id,
           issue_identifier: issue.identifier
         }}

      {:error, %Ecto.Changeset{} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:retry, {:activate, prepared}, {:run_admission, reason}}
    end
  end

  defp recover_activation(deps, prepared, run, context) do
    case ClaimStage.measure(context, :transition_recovery, fn -> deps.tracker.fetch_issue_states_by_ids([prepared.issue.id]) end) do
      {:ok, [issue]} -> activate(deps, prepared, run, issue, context)
      {:ok, []} -> execute(deps, {:abort, prepared, :claim_issue_missing}, context)
      {:error, reason} -> {:retry, {:activate, prepared}, {:transition_recovery, reason}}
    end
  end

  defp activate(deps, prepared, run, issue, context) do
    with :ok <- validate_current_state(prepared, issue),
         {:ok, started_issue} <-
           ClaimStage.measure(context, :linear_transition, fn ->
             move_to_worker_started(deps.tracker, issue, prepared.profile)
           end) do
      publishable_assignment(deps, prepared, run, started_issue, context)
    else
      {:error, reason} -> transition_failed(deps, prepared, reason, context)
    end
  end

  defp validate_current_state(prepared, issue) do
    {:ok, target} = Policy.worker_started_state(prepared.profile)
    if same_issue_state?(issue.state, prepared.issue.state) or same_issue_state?(issue.state, target), do: :ok, else: {:error, {:claim_issue_state_changed, issue.state}}
  end

  defp transition_failed(deps, prepared, reason, context) do
    if uncertain_transition?(reason),
      do: {:retry, {:activate, prepared}, {:linear_transition, reason}},
      else: execute(deps, {:abort, prepared, reason}, context)
  end

  defp uncertain_transition?({:linear_api_request, _reason}), do: true
  defp uncertain_transition?({:linear_api_status, status, _body}) when status == 429 or status in 500..599, do: true
  defp uncertain_transition?(_reason), do: false

  defp publishable_assignment(deps, prepared, run, issue, context) do
    assignment =
      ClaimStage.measure(context, :assignment_payload, fn ->
        prompt =
          PromptBuilder.build_prompt(issue,
            profile: prepared.profile,
            profile_policy: Config.workflow_profile(prepared.profile),
            allowed_updates: Config.workflow_allowed_updates(prepared.profile)
          )

        build_assignment(prepared.assignment_id, issue, run, prepared.worker, prepared.session, prepared.admission, prompt: prompt, profile: prepared.profile, expires_at: nil)
      end)

    result =
      ClaimStage.measure(context, :accepted_event, fn ->
        case deps.persistence.get_event(prepared.event_id) do
          nil ->
            deps.persistence.record_event(%{
              id: prepared.event_id,
              project_id: assignment.project_id,
              run_id: run.id,
              issue_identifier: issue.identifier,
              event_type: "task.accepted",
              payload: %{
                "correlation" => assignment.correlation,
                "dispatch_context" => Events.dispatch_context(issue)
              }
            })

          {:error, reason} ->
            {:error, reason}

          event ->
            {:ok, event}
        end
      end)

    case result do
      {:ok, _event} -> {:ok, assignment}
      {:error, reason} -> {:retry, {:activate, prepared}, {:accepted_event, reason}}
    end
  end

  defp move_to_worker_started(tracker, %Issue{} = issue, profile) do
    with {:ok, started_state} <- Policy.worker_started_state(profile) do
      maybe_transition_to_worker_started(tracker, issue, profile, started_state)
    end
  end

  defp maybe_transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
    if same_issue_state?(issue.state, started_state) do
      {:ok, %{issue | state: started_state}}
    else
      transition_to_worker_started(tracker, issue, profile, started_state)
    end
  end

  defp transition_to_worker_started(tracker, %Issue{} = issue, profile, started_state) do
    transitions = Config.settings!().workflow |> Map.get("allowed_transitions", [])

    with :ok <- Policy.validate_worker_start_transition(transitions, issue.state, profile),
         :ok <- tracker.update_issue_state(issue.id, started_state) do
      {:ok, %{issue | state: started_state}}
    end
  end

  defp build_assignment(id, issue, run, worker, session, admission, opts) do
    payload = Events.worker_assignment_payload(issue, run, admission, opts[:prompt], opts[:profile]).payload

    correlation = %{
      "project_id" => run.project_id,
      "run_id" => run.id,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "run_attempt" => run.attempt,
      "task_id" => id,
      "lease_id" => id,
      "lease_attempt" => 1,
      "worker_id" => worker.id,
      "worker_session_id" => session.id,
      "assignment_id" => id
    }

    %{
      id: id,
      task_id: id,
      lease_id: id,
      issue: issue,
      issue_identifier: issue.identifier,
      project_id: run.project_id,
      run_id: run.id,
      worker_id: worker.id,
      worker_name: Map.get(worker, :name),
      session_id: session.id,
      admission: admission,
      started_at: Map.get(run, :started_at),
      expires_at: opts[:expires_at],
      payload: payload,
      correlation: correlation,
      last_terminal_rejection: nil
    }
  end

  defp same_issue_state?(left, right), do: SymphonyElixir.StateName.normalize(left) == SymphonyElixir.StateName.normalize(right)
end
