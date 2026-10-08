defmodule SymphonyElixir.Orchestrator.Events do
  @moduledoc """
  Persistence payload shaping for orchestrator events.
  """

  alias SymphonyElixir.{Config, RunAdmission, RunFailure}
  alias SymphonyElixir.Linear.{DispatchScope, Issue}
  alias SymphonyElixir.Orchestrator.RetryPolicy

  @spec issue_snapshot(Issue.t()) :: map()
  def issue_snapshot(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "url" => issue.url,
      "labels" => issue.labels || []
    }
    |> Map.merge(DispatchScope.context_evidence(issue))
  end

  @spec event_dispatch_context(Issue.t()) :: map()
  def event_dispatch_context(%Issue{} = issue), do: DispatchScope.context_evidence(issue)

  @spec issue_attrs(Issue.t()) :: map()
  def issue_attrs(%Issue{} = issue) do
    %{
      tracker_issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      labels: %{"values" => issue.labels || []},
      snapshot: issue_snapshot(issue)
    }
  end

  @spec run_attrs(Issue.t(), RunAdmission.t(), integer() | nil) :: map()
  def run_attrs(%Issue{} = issue, %RunAdmission{} = admission, attempt) do
    %{
      issue_identifier: issue.identifier,
      status: "running",
      execution_mode: admission.execution_mode,
      attempt: RetryPolicy.normalize_attempt(attempt),
      started_at: DateTime.utc_now()
    }
  end

  @spec worker_assignment_payload(Issue.t(), map(), RunAdmission.t(), String.t(), String.t() | nil) :: map()
  def worker_assignment_payload(%Issue{} = issue, run, %RunAdmission{} = admission, prompt, profile)
      when is_map(run) do
    settings = Config.settings!()

    %{
      project_id: run.project_id,
      run_id: run.id,
      issue_identifier: issue.identifier,
      required_capabilities: %{},
      payload: %{
        "issue" => issue_snapshot(issue),
        "prompt" => prompt,
        "workflow_profile" => profile,
        "execution_mode" => admission.execution_mode,
        "source" => stringify_keys(admission.source),
        "required_gates" => settings.project.required_gates,
        "hooks" => %{
          "after_create" => settings.hooks.after_create,
          "before_run" => settings.hooks.before_run,
          "after_run" => settings.hooks.after_run,
          "before_remove" => settings.hooks.before_remove,
          "timeout_ms" => settings.hooks.timeout_ms
        },
        "limits" => stringify_keys(admission.limits),
        "codex" => codex_payload(settings.codex),
        "handoff" => %{
          "branch" => issue.branch_name,
          "issue_id" => issue.id,
          "issue_identifier" => issue.identifier,
          "issue_url" => issue.url,
          "policy" => "push_pr_then_restricted_linear",
          "allowed_updates" => Config.workflow_allowed_updates(profile)
        }
      }
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp codex_payload(codex) do
    %{
      "command" => codex.command,
      "pre_start_commands" => codex.pre_start_commands,
      "approval_policy" => codex.approval_policy,
      "thread_sandbox" => codex.thread_sandbox,
      "turn_sandbox_policy" => codex.turn_sandbox_policy
    }
    |> put_optional_codex_selector("model", codex.model)
    |> put_optional_codex_selector("reasoning_effort", codex.reasoning_effort)
  end

  defp put_optional_codex_selector(payload, _key, nil), do: payload

  defp put_optional_codex_selector(payload, key, value) when is_binary(value) do
    if String.trim(value) == "", do: payload, else: Map.put(payload, key, value)
  end

  @spec event_attrs(String.t(), String.t() | nil, map(), term()) :: map()
  def event_attrs(event_type, issue_identifier, payload, run_id \\ nil)
      when is_binary(event_type) and is_map(payload) do
    %{
      run_id: run_id,
      issue_identifier: issue_identifier,
      event_type: event_type,
      payload: payload
    }
  end

  @spec run_started_event(Issue.t(), map(), String.t() | nil) :: map()
  def run_started_event(%Issue{} = issue, run, worker_host) when is_map(run) do
    event_attrs("run.started", issue.identifier, %{issue_id: issue.id, run_id: run.id, worker_host: worker_host}, run.id)
  end

  @spec run_finished_event(map(), String.t(), :completed | RunFailure.t()) :: map()
  def run_finished_event(running_entry, status, terminal) when is_map(running_entry) and is_binary(status) do
    run_id = Map.get(running_entry, :run_id)
    failure = RunFailure.terminal_fields(terminal)

    event_attrs(
      "run.#{status}",
      Map.get(running_entry, :identifier),
      %{
        run_id: run_id,
        failure_reason: failure.failure_reason,
        failure_evidence: failure.failure_evidence
      },
      run_id
    )
  end

  @spec workspace_attrs(map()) :: map() | nil
  def workspace_attrs(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :workspace_path) do
      path when is_binary(path) ->
        %{
          issue_identifier: Map.get(running_entry, :identifier),
          path: path,
          host: Map.get(running_entry, :worker_host),
          status: "active"
        }

      _ ->
        nil
    end
  end

  @spec workspace_created_event(map()) :: map() | nil
  def workspace_created_event(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :workspace_path) do
      path when is_binary(path) ->
        event_attrs(
          "workspace.created",
          Map.get(running_entry, :identifier),
          %{path: path, host: Map.get(running_entry, :worker_host)},
          Map.get(running_entry, :run_id)
        )

      _ ->
        nil
    end
  end
end
