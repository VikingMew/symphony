defmodule SymphonyElixir.Persistence.WorkflowStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Persistence
  alias SymphonyElixir.Persistence.WorkflowStore
  alias SymphonyElixir.Persistence.WorkflowVersion

  setup do
    previous_allow_test_source = Application.get_env(:symphony_elixir, :allow_test_workflow_source)

    on_exit(fn ->
      restore_app_env(:allow_test_workflow_source, previous_allow_test_source)
    end)
  end

  test "project and workflow lookups tolerate an unavailable Repo" do
    refute Process.whereis(SymphonyElixir.Repo)

    assert WorkflowStore.default_project() == {:error, :repo_unavailable}
    assert WorkflowStore.list_projects() == []
    assert WorkflowStore.create_project(%{}) == {:error, :repo_unavailable}
    assert WorkflowStore.update_project("project-id", %{}) == {:error, :repo_unavailable}
    assert WorkflowStore.active_workflow_version() == nil
    assert WorkflowStore.list_workflow_versions() == []
  end

  test "workflow_to_loaded returns runtime shape without a Repo-backed project overlay" do
    version = %WorkflowVersion{
      id: "workflow-version-id",
      project_id: nil,
      yaml_config: %{"tracker" => %{"kind" => "linear"}},
      prompt_body: "Base prompt"
    }

    assert WorkflowStore.workflow_to_loaded(version) == %{
             config: %{"tracker" => %{"kind" => "linear"}},
             prompt: "Base prompt",
             prompt_template: "Base prompt",
             workflow_version_id: "workflow-version-id",
             project_id: nil
           }
  end

  test "export_workflow prefers raw markdown and can render stored YAML plus prompt" do
    assert WorkflowStore.export_workflow(%WorkflowVersion{raw_workflow_md: "raw workflow"}) == "raw workflow"

    rendered =
      WorkflowStore.export_workflow(%WorkflowVersion{
        yaml_config: %{"tracker" => %{"kind" => "linear"}},
        prompt_body: "Rendered prompt"
      })

    assert rendered =~ "tracker:"
    assert rendered =~ "Rendered prompt"
  end

  test "test workflow source activation is blocked when explicitly disabled" do
    Application.put_env(:symphony_elixir, :allow_test_workflow_source, false)

    assert WorkflowStore.activate_workflow_version(%WorkflowVersion{source: "test"}) ==
             {:error, :test_workflow_source_not_allowed}
  end

  test "public persistence context delegates workflow store compatibility functions" do
    version = %WorkflowVersion{raw_workflow_md: "raw workflow"}

    assert Persistence.default_project() == WorkflowStore.default_project()
    assert Persistence.list_projects() == WorkflowStore.list_projects()
    assert Persistence.active_workflow_version() == WorkflowStore.active_workflow_version()
    assert Persistence.list_workflow_versions() == WorkflowStore.list_workflow_versions()
    assert Persistence.export_workflow(version) == WorkflowStore.export_workflow(version)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
