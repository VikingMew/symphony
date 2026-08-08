defmodule SymphonyElixir.WorkflowStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Persistence, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

  defmodule RaisingPersistence do
    @moduledoc false

    def default_project, do: raise("database read failed")
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_source = Application.get_env(:symphony_elixir, :workflow_source)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    FakePersistence.reset!()

    on_exit(fn ->
      stop_repo_stub()
      restore_app_env(:persistence_module, previous_persistence)
      restore_app_env(:workflow_source, previous_source)
    end)

    :ok
  end

  test "reload logs a database fault and retains the last-known-good workflows" do
    seed_active_workflow!("Last known good prompt")
    assert :ok = WorkflowStore.force_reload()

    previous_state = :sys.get_state(WorkflowStore)
    assert previous_state.source.type == :database

    Application.put_env(:symphony_elixir, :persistence_module, Persistence)
    _pid = start_repo_stub!()

    log = capture_log(fn -> assert :ok = WorkflowStore.force_reload() end)
    retained_state = :sys.get_state(WorkflowStore)

    assert retained_state == previous_state
    assert retained_state.source.type == :database
    refute retained_state.source.type == :setup_required
    assert log =~ "Workflow persistence query failed operation=default_project outcome=failed"
    assert log =~ "Workflow reload failed action=retain_last_known_good"
  end

  test "an empty database still yields setup required" do
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
  end

  test "database query faults are returned and never reported as setup required" do
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{setup_required: true}} = WorkflowStore.current()

    Application.put_env(:symphony_elixir, :persistence_module, RaisingPersistence)
    assert :ok = WorkflowStore.force_reload()

    assert {:error, {:query_failed, %RuntimeError{message: "database read failed"}}} =
             WorkflowStore.current_with_source()

    assert {:error, {:query_failed, %RuntimeError{message: "database read failed"}}} =
             WorkflowStore.current()

    assert {:error, {:query_failed, %RuntimeError{message: "database read failed"}}} =
             Config.settings()

    assert_raise ArgumentError, ~r/Runtime configuration unavailable: database query failed/, fn ->
      Config.settings!()
    end
  end

  test "repo unavailability after an empty read is returned and never reported as setup required" do
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{setup_required: true}} = WorkflowStore.current()

    Application.put_env(:symphony_elixir, :persistence_module, Persistence)
    refute Process.whereis(SymphonyElixir.Repo)
    assert :ok = WorkflowStore.force_reload()

    assert {:error, :repo_unavailable} = WorkflowStore.current()
    assert {:error, :repo_unavailable} = Config.settings()
  end

  test "repo unavailable starts degraded and preserves a loaded workflow on reload" do
    seed_active_workflow!("Available before outage")
    assert :ok = WorkflowStore.force_reload()
    previous_state = :sys.get_state(WorkflowStore)

    Application.put_env(:symphony_elixir, :persistence_module, Persistence)
    refute Process.whereis(SymphonyElixir.Repo)

    assert {:ok, degraded_state} = WorkflowStore.init([])
    assert degraded_state.workflows == %{}
    assert degraded_state.source == %{type: :error, reason: :repo_unavailable}

    log = capture_log(fn -> assert :ok = WorkflowStore.force_reload() end)
    assert :sys.get_state(WorkflowStore) == previous_state
    assert log =~ "Workflow reload failed action=retain_last_known_good"
    assert log =~ "reason=:repo_unavailable"
  end

  defp seed_active_workflow!(prompt) do
    {:ok, loaded} = Workflow.load()
    raw = Workflow.to_markdown(loaded.config, prompt)
    {:ok, project} = FakePersistence.default_project()
    assert {:ok, _version} = FakePersistence.import_workflow(project, raw, "test")
  end

  defp start_repo_stub! do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    true = Process.register(pid, SymphonyElixir.Repo)
    pid
  end

  defp stop_repo_stub do
    case Process.whereis(SymphonyElixir.Repo) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
