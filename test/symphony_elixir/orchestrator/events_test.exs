defmodule SymphonyElixir.Orchestrator.EventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.Events

  test "issue attrs include the persisted issue snapshot" do
    issue = issue(labels: ["bug"])

    assert Events.issue_attrs(issue) == %{
             tracker_issue_id: "issue-1",
             identifier: "MT-1",
             title: "Fix it",
             state: "Ready",
             url: "https://linear.example/MT-1",
             labels: %{"values" => ["bug"]},
             snapshot: %{
               "id" => "issue-1",
               "identifier" => "MT-1",
               "title" => "Fix it",
               "description" => "Description",
               "priority" => 1,
               "state" => "Ready",
               "url" => "https://linear.example/MT-1",
               "labels" => ["bug"]
             }
           }
  end

  test "run and task attrs preserve existing payload contract" do
    issue = issue()
    workflow = %{}
    run = %{id: "run-1", project_id: "project-1"}

    run_attrs = Events.run_attrs(issue, workflow, "worker", 2)
    assert run_attrs.issue_identifier == "MT-1"
    assert run_attrs.status == "queued"
    assert run_attrs.execution_mode == "worker"
    assert run_attrs.attempt == 2

    task_attrs =
      SymphonyElixir.Config.with_workflow_context(workflow_context(), fn ->
        Events.worker_task_attrs(issue, run, workflow, "Prompt", "implementation")
      end)
    assert task_attrs.project_id == "project-1"
    assert task_attrs.run_id == "run-1"
    assert task_attrs.payload["issue"]["identifier"] == "MT-1"
    assert task_attrs.payload["prompt"] == "Prompt"
    assert task_attrs.payload["workflow_profile"] == "implementation"
    assert task_attrs.payload["execution_mode"] == "worker"
    assert task_attrs.payload["required_gates"] == [%{"name" => "make-all", "command" => "make all", "timeout_ms" => 1_800_000}]
    assert task_attrs.payload["repository"]["implementation_branch"] == "feature/mt-1"
    refute recursively_has_key?(task_attrs.payload, "workflow_version_id")
  end

  test "event attrs cover run, task, and workspace events" do
    issue = issue()
    run = %{id: "run-1"}
    task = %{id: "task-1"}
    running_entry = %{identifier: "MT-1", run_id: "run-1", workspace_path: "/tmp/work", worker_host: "worker-a"}

    assert Events.run_started_event(issue, run, "worker-a") ==
             Events.event_attrs("run.started", "MT-1", %{issue_id: "issue-1", run_id: "run-1", worker_host: "worker-a"}, "run-1")

    assert Events.task_queued_event(issue, run, task).payload == %{
             issue_id: "issue-1",
             run_id: "run-1",
             task_id: "task-1"
           }

    assert Events.run_finished_event(running_entry, "failed", "boom").payload == %{
             run_id: "run-1",
             failure_reason: "boom"
           }

    assert Events.workspace_attrs(running_entry) == %{
             issue_identifier: "MT-1",
             path: "/tmp/work",
             host: "worker-a",
             status: "active"
           }

    assert Events.workspace_created_event(running_entry).payload == %{path: "/tmp/work", host: "worker-a"}
  end

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "issue-1",
          identifier: "MT-1",
          title: "Fix it",
          description: "Description",
          priority: 1,
          state: "Ready",
          url: "https://linear.example/MT-1",
          branch_name: "feature/mt-1",
          labels: []
        ],
        attrs
      )
    )
  end

  defp workflow_context do
    %{
      config: %{
        "project" => %{
          "repository_url" => "https://github.com/openai/symphony",
          "default_branch" => "main",
          "required_gates" => [%{"name" => "make-all", "command" => "make all", "timeout_ms" => 1_800_000}]
        }
      },
      prompt_template: "Prompt"
    }
  end

  defp recursively_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &recursively_has_key?(&1, key))
  end

  defp recursively_has_key?(list, key) when is_list(list), do: Enum.any?(list, &recursively_has_key?(&1, key))
  defp recursively_has_key?(_value, _key), do: false
end
