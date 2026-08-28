defmodule SymphonyElixir.Persistence.WorkflowStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Persistence
  alias SymphonyElixir.Persistence.Project
  alias SymphonyElixir.Persistence.WorkflowRecord
  alias SymphonyElixir.Persistence.WorkflowStore

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
    assert WorkflowStore.current_workflow() == nil
  end

  test "project and workflow query faults are logged and reraised" do
    _pid = start_repo_stub!()
    project = %Project{id: "project-id"}

    log =
      capture_log(fn ->
        assert_raise ArgumentError, fn -> WorkflowStore.default_project() end
        assert_raise ArgumentError, fn -> WorkflowStore.list_projects() end
        assert_raise ArgumentError, fn -> WorkflowStore.current_workflow(project) end
      end)

    assert log =~ "Workflow persistence query failed operation=default_project outcome=failed"
    assert log =~ "Workflow persistence query failed operation=list_projects outcome=failed"
    assert log =~ "Workflow persistence query failed operation=current_workflow outcome=failed"
  end

  test "workflow_to_loaded returns runtime shape without a Repo-backed project overlay" do
    workflow = %WorkflowRecord{
      id: "workflow-id",
      project_id: nil,
      yaml_config: %{"tracker" => %{"kind" => "linear"}},
      prompt_body: "Base prompt"
    }

    assert WorkflowStore.workflow_to_loaded(workflow) == %{
             config: %{"tracker" => %{"kind" => "linear"}},
             prompt: "Base prompt",
             prompt_template: "Base prompt",
             project_id: nil
           }
  end

  test "export_workflow prefers raw markdown and can render stored YAML plus prompt" do
    assert WorkflowStore.export_workflow(%WorkflowRecord{raw_workflow_md: "raw workflow"}) == "raw workflow"

    rendered =
      WorkflowStore.export_workflow(%WorkflowRecord{
        yaml_config: %{"tracker" => %{"kind" => "linear"}},
        prompt_body: "Rendered prompt"
      })

    assert rendered =~ "tracker:"
    assert rendered =~ "Rendered prompt"
  end

  test "public persistence context delegates current workflow functions" do
    workflow = %WorkflowRecord{raw_workflow_md: "raw workflow"}

    assert Persistence.default_project() == WorkflowStore.default_project()
    assert Persistence.list_projects() == {:error, :repo_unavailable}
    assert WorkflowStore.list_projects() == []
    assert Persistence.current_workflow() == WorkflowStore.current_workflow()
    assert Persistence.export_workflow(workflow) == WorkflowStore.export_workflow(workflow)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_repo_stub! do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    true = Process.register(pid, SymphonyElixir.Repo)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end
end
