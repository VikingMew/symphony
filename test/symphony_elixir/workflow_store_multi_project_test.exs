defmodule SymphonyElixir.WorkflowStoreMultiProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{PersistenceProvider, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    on_exit(fn ->
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

  test "current uses the configured default workflow when multiple projects exist" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md own this selection order.
    raw = sample_workflow_markdown()

    {:ok, fixture_project} = FakePersistence.update_project("fake-project-id", %{enabled: false})
    {:ok, _fixture_workflow} = FakePersistence.import_workflow(fixture_project, raw, "test")

    {:ok, default} =
      FakePersistence.create_project(%{
        name: "Default",
        slug: "default",
        linear_project_slug: "default-linear",
        repository_url: "git@github.com:VikingMew/default.git",
        enabled: true
      })

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
    assert {:ok, %{project_id: default_id}} = WorkflowStore.current()
    assert {:ok, %{project_id: ^default_id}} = WorkflowStore.for_project(default.id)
    assert default_id == default.id
  end

  test "current uses the only enabled loaded workflow when default is disabled" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md allow this single-project no-context read.
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
    {:ok, _default} = FakePersistence.update_project(default.id, %{enabled: false})

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{project_id: project_b_id}} = WorkflowStore.current()
    assert project_b_id == project_b.id
  end

  test "current requires project context when multiple enabled loaded workflows exist without configured default" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md prohibit selecting the first project here.
    raw = sample_workflow_markdown()
    {:ok, fixture_project} = FakePersistence.default_project()
    {:ok, _fixture_workflow} = FakePersistence.import_workflow(fixture_project, raw, "test")
    {:ok, _disabled_fixture} = FakePersistence.update_project(fixture_project.id, %{enabled: false})

    {:ok, project_a} =
      FakePersistence.create_project(%{
        name: "Project A",
        slug: "project-a",
        linear_project_slug: "linear-a",
        repository_url: "git@github.com:VikingMew/project-a.git",
        enabled: true
      })

    {:ok, _project_a_workflow} = FakePersistence.import_workflow(project_a, raw, "test")

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        linear_project_slug: "linear-b",
        repository_url: "git@github.com:VikingMew/project-b.git",
        enabled: true
      })

    {:ok, _project_b_workflow} = FakePersistence.import_workflow(project_b, raw, "test")

    assert :ok = WorkflowStore.force_reload()
    assert MapSet.new(Enum.map(WorkflowStore.list_enabled(), & &1.project_id)) == MapSet.new([project_a.id, project_b.id])
    assert {:error, :missing_project_context} = WorkflowStore.current()
    assert {:error, :missing_project_context} = WorkflowStore.current_with_source()
  end

  test "default placeholder without repository URL is not published as an enabled workflow" do
    raw = sample_workflow_markdown()
    {:ok, fixture_project} = FakePersistence.update_project("fake-project-id", %{enabled: false})
    {:ok, _} = FakePersistence.import_workflow(fixture_project, raw, "test")

    {:ok, placeholder} =
      FakePersistence.create_project(%{
        name: "Default",
        slug: "default",
        linear_project_slug: "project",
        repository_url: nil,
        enabled: true
      })

    {:ok, _} = FakePersistence.import_workflow(placeholder, raw, "test")

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
    assert [%{project_id: project_b_id}] = WorkflowStore.list_enabled()
    assert project_b_id == project_b.id
    assert {:ok, %{project_id: current_project_id}} = WorkflowStore.current()
    assert current_project_id == project_b.id
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

  test "workflow and project mutations publish complete first-read snapshots" do
    {:ok, loaded} = Workflow.load()
    {:ok, default} = FakePersistence.default_project()
    default = update_project!(default, %{slug: "default"})
    default_raw = Workflow.to_markdown(loaded.config, "Default prompt")

    assert {:ok, _default_workflow} =
             FakePersistence.import_workflow(default, default_raw, "default-import")
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:ok, %{prompt: "Default prompt"}} = WorkflowStore.current()

    assert {:ok, %{source: %{project_ids: project_ids}}} = WorkflowStore.current_with_source()
    assert default.id in project_ids

    assert {:ok, project_b} =
             FakePersistence.create_project(%{
               name: "Project B",
               slug: "project-b",
               linear_project_slug: "linear-b",
               repository_url: "git@github.com:VikingMew/project-b.git",
               enabled: true
             })
             |> PersistenceProvider.publish_runtime_mutation()

    b_raw = Workflow.to_markdown(loaded.config, "Project B old prompt")

    assert {:ok, b_old_version} =
             FakePersistence.import_workflow(project_b, b_raw, "project-b-old")
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:ok, %{prompt: "Project B old prompt"}} = WorkflowStore.for_project(project_b.id)

    b_new_raw = Workflow.to_markdown(loaded.config, "Project B new prompt")

    assert {:ok, b_new_workflow} =
             FakePersistence.import_workflow(project_b, b_new_raw, "project-b-new")
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:ok, %{prompt: "Project B new prompt"}} = WorkflowStore.for_project(project_b.id)

    assert b_new_workflow.id == b_old_version.id

    assert {:ok, updated_b} =
             FakePersistence.update_project(project_b.id, %{before_run_hook: "echo project-b"})
             |> PersistenceProvider.publish_runtime_mutation()

    assert updated_b.before_run_hook == "echo project-b"
    assert {:ok, b_workflow} = WorkflowStore.for_project(project_b.id)
    assert get_in(b_workflow.config, ["hooks", "before_run"]) == "echo project-b"

    assert {:ok, _disabled_default} =
             FakePersistence.update_project(default.id, Map.merge(default, %{enabled: false}))
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:ok, %{project_id: project_b_id}} = WorkflowStore.current()
    assert project_b_id == project_b.id
    assert {:ok, %{project_id: project_b_id}} = WorkflowStore.for_project(project_b.id)
    assert project_b_id == project_b.id

    assert {:ok, _enabled_default} =
             FakePersistence.update_project(default.id, Map.merge(default, %{enabled: true}))
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:ok, %{project_id: default_project_id}} = WorkflowStore.current()
    assert default_project_id == default.id

    assert {:ok, _disabled_b} =
             FakePersistence.update_project(project_b.id, %{enabled: false})
             |> PersistenceProvider.publish_runtime_mutation()

    assert Enum.map(WorkflowStore.list_enabled(), & &1.project_id) == [default.id]
    assert {:ok, %{project_id: default_project_id}} = WorkflowStore.current()
    assert default_project_id == default.id

    assert {:ok, _enabled_b} =
             FakePersistence.update_project(project_b.id, %{enabled: true})
             |> PersistenceProvider.publish_runtime_mutation()

    assert MapSet.new(Enum.map(WorkflowStore.list_enabled(), & &1.project_id)) ==
             MapSet.new([default.id, project_b.id])

    assert {:ok, _deleted} =
             FakePersistence.delete_project(project_b.id)
             |> PersistenceProvider.publish_runtime_mutation()

    assert {:error, :not_found} = WorkflowStore.for_project(project_b.id)

    assert {:ok, %{source: %{project_ids: final_project_ids}}} = WorkflowStore.current_with_source()
    assert final_project_ids == [default.id]
    assert project_b.id in final_project_ids == false
    assert b_new_workflow.id == b_old_version.id
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp update_project!(project, attrs) do
    {:ok, updated} = FakePersistence.update_project(project.id, Map.merge(project, attrs))
    updated
  end
end
