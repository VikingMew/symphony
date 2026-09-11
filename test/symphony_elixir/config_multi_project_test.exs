defmodule SymphonyElixir.ConfigMultiProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, TestSupport.FakePersistence, Workflow, WorkflowStore}

  defp loaded_workflow_with_prompt(prompt) do
    raw =
      Workflow.load()
      |> then(fn {:ok, workflow} ->
        Workflow.to_markdown(workflow.config, String.replace(workflow.prompt, "You are an agent", prompt))
      end)

    {:ok, loaded} = Workflow.parse_content(raw)
    loaded
  end

  test "with_workflow_context makes settings! return the override workflow" do
    workflow_a = loaded_workflow_with_prompt("Project A agent")
    workflow_b = loaded_workflow_with_prompt("Project B agent")
    default_prompt = Config.workflow_prompt()

    assert Config.settings!().workflow != nil

    result =
      Config.with_workflow_context(workflow_a, fn ->
        prompt_a = Config.workflow_prompt()
        tracker_a = Config.settings!().tracker.project_slug

        inner =
          Config.with_workflow_context(workflow_b, fn ->
            %{prompt: Config.workflow_prompt(), tracker: Config.settings!().tracker.project_slug}
          end)

        %{prompt_a: prompt_a, tracker_a: tracker_a, inner: inner}
      end)

    assert result.prompt_a == "Project A agent for this repository."
    assert result.tracker_a == "project"
    assert result.inner.prompt == "Project B agent for this repository."

    # Context is restored after the block.
    assert Config.workflow_prompt() == default_prompt
  end

  test "with_workflow_context restores previous context after nested use" do
    workflow_a = loaded_workflow_with_prompt("Project A agent")
    workflow_b = loaded_workflow_with_prompt("Project B agent")
    default_prompt = Config.workflow_prompt()

    Config.with_workflow_context(workflow_a, fn ->
      Config.with_workflow_context(workflow_b, fn -> :ok end)
      assert Config.workflow_prompt() == "Project A agent for this repository."
    end)

    assert Config.workflow_prompt() == default_prompt
  end

  test "current_workflow uses the configured default when multiple projects exist" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md own the no-context resolution contract.
    raw = sample_workflow_markdown()
    {:ok, fixture_project} = FakePersistence.update_project("fake-project-id", %{enabled: false})
    {:ok, _fixture_workflow} = FakePersistence.import_workflow(fixture_project, raw, "test")

    {:ok, default_project} =
      FakePersistence.create_project(%{
        name: "Default",
        slug: "default",
        linear_project_slug: "default-linear",
        repository_url: "git@github.com:VikingMew/default.git",
        enabled: true
      })

    {:ok, _default_workflow} = FakePersistence.import_workflow(default_project, raw, "test")

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

    assert {:ok, %{project_id: default_project_id}} = Config.current_workflow()
    assert default_project_id == default_project.id
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.project_slug == "default-linear"

    {:ok, loaded} = Workflow.load()
    assert {:ok, _settings} = Config.with_workflow_context(loaded, fn -> Config.settings() end)
  end

  test "current_workflow uses the only enabled loaded workflow without configured default" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md allow the single loaded workflow case.
    raw = sample_workflow_markdown()
    {:ok, fixture_project} = FakePersistence.default_project()
    {:ok, _fixture_workflow} = FakePersistence.import_workflow(fixture_project, raw, "test")
    {:ok, _disabled_fixture} = FakePersistence.update_project(fixture_project.id, %{enabled: false})

    {:ok, project} =
      FakePersistence.create_project(%{
        name: "Project A",
        slug: "project-a",
        linear_project_slug: "linear-a",
        repository_url: "git@github.com:VikingMew/project-a.git",
        enabled: true
      })

    {:ok, _workflow} = FakePersistence.import_workflow(project, raw, "test")
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{project_id: project_id}} = Config.current_workflow()
    assert project_id == project.id
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.project_slug == "linear-a"
  end

  test "current_workflow requires project context with multiple enabled loaded workflows and no configured default" do
    # docs/remove-default-project-dependency-design.md and
    # docs/default-project-bootstrap-and-remove-design.md require this typed error.
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

    assert {:error, :missing_project_context} = Config.current_workflow()
    assert {:error, :missing_project_context} = Config.settings()

    {:ok, loaded} = Workflow.load()
    assert {:ok, _settings} = Config.with_workflow_context(loaded, fn -> Config.settings() end)
  end

  defp sample_workflow_markdown do
    Workflow.load()
    |> then(fn {:ok, workflow} -> Workflow.to_markdown(workflow.config, workflow.prompt) end)
  end
end
