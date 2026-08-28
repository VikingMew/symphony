defmodule SymphonyElixir.Orchestrator.Events do
  @moduledoc """
  Persistence payload shaping for orchestrator events.
  """

  alias SymphonyElixir.Linear.Issue
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
    %{
      project_id: run.project_id,
      run_id: run.id,
      issue_identifier: issue.identifier,
      required_capabilities: %{},
      payload: %{
        "issue" => issue_snapshot(issue),
        "prompt" => prompt,
        "workflow_profile" => profile,
        "execution_mode" => "worker"
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
