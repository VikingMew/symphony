defmodule SymphonyElixir.Persistence.WorkflowStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
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
    assert Process.whereis(SymphonyElixir.Repo) == nil

    assert WorkflowStore.default_project() == {:error, :repo_unavailable}
    assert WorkflowStore.list_projects() == []
    assert WorkflowStore.create_project(%{}) == {:error, :repo_unavailable}
    assert WorkflowStore.update_project("project-id", %{}) == {:error, :repo_unavailable}
    assert WorkflowStore.current_workflow() == nil
    assert WorkflowStore.legacy_instance_workflow_status() == {:error, :repo_unavailable}
    assert WorkflowStore.reconcile_legacy_instance_workflow("project") == {:error, :repo_unavailable}
  end

  test "project hook writes are rejected before persistence" do
    assert {:error, {:out_of_scope_project_fields, ["after_create_hook"]}} =
             WorkflowStore.create_project(Map.put(%{after_create_hook: nil}, "after_create_hook", "mix setup"))
  end

  test "project records reject instance workflow sections before persistence" do
    assert {:error, {:out_of_scope_project_fields, ["codex"]}} =
             WorkflowStore.create_project(%{"codex" => %{"model" => "gpt-5.5"}})
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

  test "workflow_to_loaded composes the instance and project slices" do
    workflow = %WorkflowRecord{
      id: "workflow-id",
      project_id: nil,
      yaml_config: %{"tracker" => %{"kind" => "linear"}},
      prompt_body: ""
    }

    instance = %{config: %{"polling" => %{"interval_ms" => 1_000}}, prompt_body: "Base prompt"}

    assert {:ok, loaded} = WorkflowStore.workflow_to_loaded(instance, workflow)

    assert loaded == %{
             config: %{
               "polling" => %{"interval_ms" => 1_000},
               "tracker" => %{"kind" => "linear"},
               "workflow" => Schema.default_workflow_policy()
             },
             prompt: "Base prompt",
             prompt_template: "Base prompt",
             project_id: nil
           }
  end

  test "export_workflow renders only canonical project YAML" do
    assert {:ok, rendered} =
             WorkflowStore.export_workflow(%WorkflowRecord{
               yaml_config: %{"tracker" => %{"kind" => "linear"}},
               prompt_body: ""
             })

    assert rendered =~ "tracker:"
    assert rendered =~ "Rendered prompt" == false
  end

  test "export_workflow rejects persisted instance fields" do
    assert {:error, {:out_of_scope_workflow_fields, :project, ["prompt_body"]}} =
             WorkflowStore.export_workflow(%WorkflowRecord{
               yaml_config: %{"codex" => %{"model" => "gpt-5.5"}},
               prompt_body: "Rendered prompt"
             })
  end

  test "export_workflow rejects persisted instance config with a blank prompt" do
    assert {:error, {:out_of_scope_workflow_fields, :project, ["codex"]}} =
             WorkflowStore.export_workflow(%WorkflowRecord{
               yaml_config: %{"codex" => %{"model" => "gpt-5.5"}},
               prompt_body: ""
             })
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
