defmodule SymphonyElixir.WorkflowStoreMultiProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.{Workflow, WorkflowStore}

  setup do
    previous_source = Application.get_env(:symphony_elixir, :workflow_source)
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:workflow_source, previous_source)
      restore_app_env(:persistence_module, previous_persistence)
    end)

    :ok
  end

  defp sample_workflow_markdown do
    Workflow.load()
    |> then(fn {:ok, workflow} -> Workflow.to_markdown(workflow.config, workflow.prompt) end)
  end

  test "list_enabled returns one loaded workflow per enabled project" do
    raw = sample_workflow_markdown()
    {:ok, default} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: true
      })

    {:ok, _} = FakePersistence.import_workflow(project_b, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert length(WorkflowStore.list_enabled()) == 2

    {:ok, default_workflow} = WorkflowStore.for_project(default.id)
    {:ok, b_workflow} = WorkflowStore.for_project(project_b.id)
    assert default_workflow.project_id == default.id
    assert b_workflow.project_id == project_b.id
  end

  test "current returns the default project workflow" do
    raw = sample_workflow_markdown()
    {:ok, default} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: true
      })

    {:ok, _} = FakePersistence.import_workflow(project_b, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.project_id == default.id
  end

  test "for_project returns not_found for unknown project" do
    raw = sample_workflow_markdown()
    {:ok, default} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert {:error, :not_found} = WorkflowStore.for_project("missing-project-id")
  end

  test "disabled projects are excluded from list_enabled" do
    raw = sample_workflow_markdown()
    {:ok, default} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: false
      })

    {:ok, _} = FakePersistence.import_workflow(project_b, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert [workflow] = WorkflowStore.list_enabled()
    assert workflow.project_id == default.id
  end

  test "project hooks overlay workflow hooks in loaded config" do
    raw = sample_workflow_markdown()
    {:ok, default} = FakePersistence.default_project()

    FakePersistence.put_default_project_attrs!(%{before_run_hook: "echo hello from project"})
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.for_project(default.id)
    assert get_in(workflow.config, ["hooks", "before_run"]) == "echo hello from project"
  end

  test "unset project hooks leave workflow hooks untouched" do
    raw =
      sample_workflow_markdown()
      |> String.replace("agent:", "hooks:\n  before_run: echo workflow-level\nagent:")

    {:ok, default} = FakePersistence.default_project()
    {:ok, _} = FakePersistence.import_workflow(default, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.for_project(default.id)
    assert get_in(workflow.config, ["hooks", "before_run"]) == "echo workflow-level"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
