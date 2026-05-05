defmodule SymphonyElixir.WorkflowStoreFakePersistenceTest do
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

  test "database source loads active workflow through fake persistence when file is missing" do
    raw =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace("You are an agent", "You are a fake database agent")

    {:ok, project} = FakePersistence.default_project()
    assert {:ok, _version} = FakePersistence.import_workflow(project, raw, "test")

    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")
    Workflow.set_workflow_file_path(missing_path)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{workflow: workflow, source: source}} = WorkflowStore.current_with_source()
    assert workflow.prompt =~ "fake database agent"
    assert source.type == :database
    refute Map.get(workflow, :setup_required, false)
  end

  test "database source seeds through fake persistence when active workflow is missing" do
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{workflow: workflow, source: source}} = WorkflowStore.current_with_source()
    assert workflow.prompt =~ "You are an agent"
    assert source.type == :database
    assert FakePersistence.active_workflow_version()
  end

  test "database source provides setup workflow when file and active workflow are missing" do
    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")
    Workflow.set_workflow_file_path(missing_path)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{workflow: workflow, source: source}} = WorkflowStore.current_with_source()
    assert workflow.setup_required
    assert source.type == :setup_required
    assert get_in(workflow.config, ["tracker", "kind"]) == "memory"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
