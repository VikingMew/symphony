defmodule SymphonyElixir.WorkflowStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Persistence, Workflow, WorkflowStore}
  alias SymphonyElixir.TestSupport.FakePersistence

  defmodule RaisingPersistence do
    @moduledoc false

    def default_project, do: raise("database read failed")
  end

  defmodule InstrumentedPersistence do
    @moduledoc false

    alias SymphonyElixir.TestSupport.FakePersistence

    def start_link do
      Agent.start_link(fn -> %{calls: 0, block_at: nil, owner: nil} end, name: __MODULE__)
    end

    def reset! do
      Agent.update(__MODULE__, fn _ -> %{calls: 0, block_at: nil, owner: nil} end)
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def block_once(point, owner) do
      Agent.update(__MODULE__, &Map.merge(&1, %{block_at: point, owner: owner}))
    end

    def default_project, do: counted(:default_project, &FakePersistence.default_project/0)
    def list_projects, do: counted(:list_projects, &FakePersistence.list_projects/0)

    def active_workflow_version(project) do
      counted(:active_workflow_version, fn -> FakePersistence.active_workflow_version(project) end)
    end

    def workflow_to_loaded(version) do
      counted(:workflow_to_loaded, fn -> FakePersistence.workflow_to_loaded(version) end)
    end

    defp counted(point, fun) do
      blocker =
        Agent.get_and_update(__MODULE__, fn state ->
          state = Map.update!(state, :calls, &(&1 + 1))

          if state.block_at == point do
            {state.owner, %{state | block_at: nil}}
          else
            {nil, state}
          end
        end)

      if blocker do
        send(blocker, {:persistence_blocked, point, self()})

        receive do
          :release -> :ok
        end
      end

      fun.()
    end
  end

  defmodule EdgePersistence do
    @moduledoc false

    def default_project, do: response(:default_project)
    def list_projects, do: response(:projects)
    def active_workflow_version(_project), do: response(:active_version)
    def workflow_to_loaded(%{loaded: loaded}), do: loaded

    defp response(key) do
      :symphony_elixir
      |> Application.fetch_env!(:workflow_store_edge)
      |> Map.fetch!(key)
    end
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    if is_nil(Process.whereis(InstrumentedPersistence)) do
      start_supervised!(%{id: InstrumentedPersistence, start: {InstrumentedPersistence, :start_link, []}})
    end

    InstrumentedPersistence.reset!()

    on_exit(fn ->
      stop_repo_stub()
      Application.delete_env(:symphony_elixir, :workflow_store_edge)
      restore_app_env(:persistence_module, previous_persistence)
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

    log =
      capture_log(fn ->
        assert {:error, {:refresh_failed, {:query_failed, %ArgumentError{}}}} =
                 WorkflowStore.force_reload()
      end)

    retained_state = :sys.get_state(WorkflowStore)

    assert retained_state.workflows == previous_state.workflows
    assert retained_state.default_project_id == previous_state.default_project_id
    assert retained_state.source == previous_state.source
    assert retained_state.source.type == :database
    refute retained_state.source.type == :setup_required
    assert log =~ "Workflow persistence query failed operation=default_project outcome=failed"
    assert log =~ "Workflow refresh failed action=retain_last_known_good"
  end

  test "an empty database still yields setup required" do
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
  end

  test "database query faults retain a valid setup-required snapshot" do
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{setup_required: true}} = WorkflowStore.current()

    Application.put_env(:symphony_elixir, :persistence_module, RaisingPersistence)

    assert {:error, {:refresh_failed, {:query_failed, %RuntimeError{message: "database read failed"}}}} =
             WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()

    assert {:error, :setup_required} = Config.settings()

    assert_raise ArgumentError, ~r/No active workflow is configured/, fn ->
      Config.settings!()
    end
  end

  test "repo unavailability after an empty read retains setup required" do
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{setup_required: true}} = WorkflowStore.current()

    Application.put_env(:symphony_elixir, :persistence_module, Persistence)
    refute Process.whereis(SymphonyElixir.Repo)
    assert {:error, {:refresh_failed, :repo_unavailable}} = WorkflowStore.force_reload()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
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

    log = capture_log(fn -> assert {:error, {:refresh_failed, :repo_unavailable}} = WorkflowStore.force_reload() end)
    retained_state = :sys.get_state(WorkflowStore)
    assert retained_state.workflows == previous_state.workflows
    assert retained_state.source == previous_state.source
    assert log =~ "Workflow refresh failed action=retain_last_known_good"
    assert log =~ "reason=:repo_unavailable"
  end

  test "published workflow reads make no persistence calls" do
    seed_active_workflow!("Memory-only prompt")
    Application.put_env(:symphony_elixir, :persistence_module, InstrumentedPersistence)
    assert :ok = WorkflowStore.force_reload()
    baseline = InstrumentedPersistence.calls()

    for _ <- 1..5 do
      assert {:ok, %{prompt: "Memory-only prompt", project_id: project_id}} = WorkflowStore.current()

      assert {:ok, %{workflow: %{prompt: "Memory-only prompt"}, source: %{type: :database}}} =
               WorkflowStore.current_with_source()

      assert [%{prompt: "Memory-only prompt"}] = WorkflowStore.list_enabled()
      assert {:ok, %{prompt: "Memory-only prompt"}} = WorkflowStore.for_project(project_id)
    end

    assert InstrumentedPersistence.calls() == baseline
  end

  test "readers and status config stay available while a single background refresh is blocked" do
    seed_active_workflow!("Available during refresh")
    Application.put_env(:symphony_elixir, :persistence_module, InstrumentedPersistence)
    assert :ok = WorkflowStore.force_reload()

    InstrumentedPersistence.block_once(:default_project, self())
    send(WorkflowStore, :poll)
    assert_receive {:persistence_blocked, :default_project, blocked_pid}

    refresh = :sys.get_state(WorkflowStore).refresh
    assert refresh.pid == blocked_pid

    Enum.each(1..3, fn _ -> send(WorkflowStore, :poll) end)
    assert :sys.get_state(WorkflowStore).refresh.pid == blocked_pid

    assert {:ok, %{prompt: "Available during refresh"}} = WorkflowStore.current()
    assert {:ok, %{workflow: %{prompt: "Available during refresh"}}} = WorkflowStore.current_with_source()
    assert [%{prompt: "Available during refresh"}] = WorkflowStore.list_enabled()
    assert {:ok, workflow} = WorkflowStore.current()
    assert {:ok, ^workflow} = WorkflowStore.for_project(workflow.project_id)
    assert {:ok, dashboard_state} = SymphonyElixir.StatusDashboard.init(enabled: false)
    assert dashboard_state.refresh_ms > 0
    assert Process.alive?(Process.whereis(WorkflowStore))

    send(blocked_pid, :release)
    assert_eventually(fn -> is_nil(:sys.get_state(WorkflowStore).refresh) end)
  end

  test "an older delayed background refresh cannot overwrite explicit publication" do
    seed_active_workflow!("Old prompt")
    Application.put_env(:symphony_elixir, :persistence_module, InstrumentedPersistence)
    assert :ok = WorkflowStore.force_reload()

    InstrumentedPersistence.block_once(:workflow_to_loaded, self())
    send(WorkflowStore, :poll)
    assert_receive {:persistence_blocked, :workflow_to_loaded, blocked_pid}

    seed_active_workflow!("New prompt")
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "New prompt"}} = WorkflowStore.current()

    send(blocked_pid, :release)
    assert_eventually(fn -> is_nil(:sys.get_state(WorkflowStore).refresh) end)
    assert {:ok, %{prompt: "New prompt"}} = WorkflowStore.current()
  end

  test "typed persistence edge results never replace the published snapshot" do
    seed_active_workflow!("Retained prompt")
    assert :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :persistence_module, EdgePersistence)

    loaded = %{project_id: "edge", prompt: "Edge prompt", workflow_version_id: "version-edge"}
    project = %{id: "edge", enabled: true}
    version = %{loaded: loaded}

    put_edge(default_project: {:error, :not_found}, projects: [project], active_version: version)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, ^loaded} = WorkflowStore.current()

    put_edge(default_project: {:error, :invalid_default}, projects: [], active_version: nil)

    assert {:error, {:refresh_failed, {:query_failed, {:default_project, :invalid_default}}}} =
             WorkflowStore.force_reload()

    put_edge(default_project: {:ok, project}, projects: {:error, :projects_failed}, active_version: nil)
    assert {:error, {:refresh_failed, {:query_failed, :projects_failed}}} = WorkflowStore.force_reload()

    put_edge(default_project: {:ok, project}, projects: :invalid_projects, active_version: nil)

    assert {:error, {:refresh_failed, {:query_failed, {:invalid_list_projects_result, :invalid_projects}}}} =
             WorkflowStore.force_reload()

    put_edge(default_project: {:ok, project}, projects: [project], active_version: {:error, :repo_unavailable})
    assert {:error, {:refresh_failed, :repo_unavailable}} = WorkflowStore.force_reload()

    put_edge(default_project: {:ok, project}, projects: [project], active_version: {:error, :version_failed})

    assert {:error, {:refresh_failed, {:query_failed, {:active_workflow_version, "edge", :version_failed}}}} =
             WorkflowStore.force_reload()
  end

  test "callback guards discard stale messages and clear failed background work" do
    state = %WorkflowStore.State{
      workflows: %{},
      default_project_id: nil,
      source: %{type: :setup_required},
      generation: 2,
      refresh: nil
    }

    assert {:noreply, ^state} =
             WorkflowStore.handle_info({:workflow_refresh_result, make_ref(), 1, {:ok, state}}, state)

    assert {:noreply, ^state} =
             WorkflowStore.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)

    monitor_ref = make_ref()
    refreshing = %{state | refresh: %{monitor: monitor_ref}}

    assert capture_log(fn ->
             assert {:noreply, %WorkflowStore.State{refresh: nil}} =
                      WorkflowStore.handle_info({:DOWN, monitor_ref, :process, self(), :boom}, refreshing)
           end) =~ "mode=background"

    waiting = spawn(fn -> Process.sleep(:infinity) end)
    task_monitor_ref = Process.monitor(waiting)
    token = make_ref()
    refreshing = %{state | refresh: %{monitor: task_monitor_ref, token: token}}

    assert capture_log(fn ->
             assert {:noreply, %WorkflowStore.State{refresh: nil}} =
                      WorkflowStore.handle_info(
                        {:workflow_refresh_result, token, 2, {:error, :repo_unavailable}},
                        refreshing
                      )
           end) =~ "reason=:repo_unavailable"

    Process.exit(waiting, :kill)
  end

  defp put_edge(values) do
    Application.put_env(:symphony_elixir, :workflow_store_edge, Map.new(values))
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

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
