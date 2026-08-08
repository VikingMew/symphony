defmodule SymphonyElixir.WorkflowStoreFakePersistenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

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
      Workflow.load()
      |> then(fn {:ok, workflow} ->
        Workflow.to_markdown(
          workflow.config,
          String.replace(workflow.prompt, "You are an agent", "You are a fake database agent")
        )
      end)

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

  test "database source reports no active workflow when the database is empty even if local package exists" do
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
    refute FakePersistence.active_workflow_version()
  end

  test "database source keeps setup-required semantics at the Config boundary when files and workflow are missing" do
    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")
    Workflow.set_workflow_file_path(missing_path)

    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
