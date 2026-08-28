defmodule SymphonyElixir.Orchestrator.Events do
  @moduledoc """
  Persistence payload shaping for orchestrator events.
  """

  alias SymphonyElixir.{Config, Linear.Issue}
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
  end

  @spec issue_attrs(Issue.t()) :: map()
  def issue_attrs(%Issue{} = issue) do
    %{
      tracker_issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      labels: %{"values" => issue.labels || []},
      snapshot: issue_snapshot(issue)
    }
  end

  @spec run_attrs(Issue.t(), map() | nil, String.t(), integer() | nil) :: map()
  def run_attrs(%Issue{} = issue, _workflow, execution_mode, attempt)
      when execution_mode in ["centralized", "worker"] do
    %{
      issue_identifier: issue.identifier,
      status: if(execution_mode == "worker", do: "queued", else: "running"),
      execution_mode: execution_mode,
      attempt: RetryPolicy.normalize_attempt(attempt),
      started_at: DateTime.utc_now()
    }
  end

  @spec worker_task_attrs(Issue.t(), map(), map() | nil, String.t(), String.t() | nil) :: map()
  def worker_task_attrs(%Issue{} = issue, run, _workflow, prompt, profile) when is_map(run) do
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
        "execution_mode" => "worker",
        "repository" => %{
          "project_id" => run.project_id,
          "url" => settings.project.repository_url,
          "source_ref" => settings.project.default_branch,
          "implementation_branch" => issue.branch_name
        },
        "required_gates" => settings.project.required_gates,
        "hooks" => %{
          "after_create" => settings.hooks.after_create,
          "before_run" => settings.hooks.before_run,
          "after_run" => settings.hooks.after_run,
          "before_remove" => settings.hooks.before_remove,
          "timeout_ms" => settings.hooks.timeout_ms
        },
        "limits" => %{
          "max_turns" => settings.agent.max_turns,
          "turn_timeout_ms" => settings.codex.turn_timeout_ms,
          "read_timeout_ms" => settings.codex.read_timeout_ms,
          "stall_timeout_ms" => settings.codex.stall_timeout_ms
        },
        "codex" => %{
          "command" => settings.codex.command,
          "pre_start_commands" => settings.codex.pre_start_commands,
          "approval_policy" => settings.codex.approval_policy,
          "thread_sandbox" => settings.codex.thread_sandbox,
          "turn_sandbox_policy" => settings.codex.turn_sandbox_policy
        },
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

  @spec task_queued_event(Issue.t(), map(), map()) :: map()
  def task_queued_event(%Issue{} = issue, run, task) when is_map(run) and is_map(task) do
    event_attrs("task.queued", issue.identifier, %{issue_id: issue.id, run_id: run.id, task_id: task.id}, run.id)
  end

  @spec run_finished_event(map(), String.t(), String.t() | nil) :: map()
  def run_finished_event(running_entry, status, failure_reason) when is_map(running_entry) and is_binary(status) do
    run_id = Map.get(running_entry, :run_id)

    event_attrs(
      "run.#{status}",
      Map.get(running_entry, :identifier),
      %{run_id: run_id, failure_reason: failure_reason},
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
