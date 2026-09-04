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
    refute Config.workflow_prompt() == "Project A agent"
  end

  test "with_workflow_context restores previous context after nested use" do
    workflow_a = loaded_workflow_with_prompt("Project A agent")
    workflow_b = loaded_workflow_with_prompt("Project B agent")

    Config.with_workflow_context(workflow_a, fn ->
      Config.with_workflow_context(workflow_b, fn -> :ok end)
      assert Config.workflow_prompt() == "Project A agent for this repository."
    end)

    refute Config.workflow_prompt() == "Project A agent for this repository."
  end

  test "current_workflow requires explicit context when real projects exist" do
    {:ok, project} =
      FakePersistence.create_project(%{
        name: "Project B",
        slug: "project-b",
        enabled: true
      })

    {:ok, loaded} = Workflow.load()
    raw = Workflow.to_markdown(loaded.config, loaded.prompt)
    {:ok, _workflow} = FakePersistence.import_workflow(project, raw, "test")
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :missing_project_context} = Config.current_workflow()
    assert {:error, :missing_project_context} = Config.settings()

    assert_raise ArgumentError, ~r/explicit project context is required/, fn ->
      Config.settings!()
    end

    assert {:ok, _settings} = Config.with_workflow_context(loaded, fn -> Config.settings() end)
  end
end
