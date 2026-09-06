defmodule SymphonyElixir.Worker.RuntimeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Worker.{Config, Runtime}

  defmodule FakeClient do
    def protocol_version, do: "worker-api-v1"

    def register(_config) do
      {:ok, %{"worker_id" => "worker-1", "session_id" => "session-1", "heartbeat_interval_seconds" => 60}}
    end

    def claim(_config, request), do: Agent.get_and_update(__MODULE__, &pop_claim(&1, request))

    def heartbeat(_config, _identity, payload) do
      Agent.update(__MODULE__, &update_in(&1.heartbeats, fn values -> [payload | values] end))
      {:ok, %{"commands" => []}}
    end

    def event(_config, _identity, task_id, type, payload) do
      Agent.get_and_update(__MODULE__, fn state ->
        outcomes = Map.get(state.outcomes, type, [])
        {outcome, outcomes} = pop_outcome(outcomes)
        state = %{state | events: state.events ++ [{task_id, type, payload}], outcomes: Map.put(state.outcomes, type, outcomes)}
        {outcome, state}
      end)
    end

    defp pop_claim(state, %{"available_slots" => 0} = request) do
      {{:ok, %{"task" => nil}}, %{state | claims_seen: state.claims_seen ++ [request]}}
    end

    defp pop_claim(%{claims: [claim | claims]} = state, request), do: {{:ok, claim}, %{state | claims: claims, claims_seen: state.claims_seen ++ [request]}}
    defp pop_claim(state, request), do: {{:ok, %{"task" => nil}}, %{state | claims_seen: state.claims_seen ++ [request]}}
    defp pop_outcome([outcome | rest]), do: {outcome, rest}
    defp pop_outcome([]), do: {{:ok, %{}}, []}
  end

  defmodule FakeExecutor do
    def execute(_config, claim, progress) do
      test = Agent.get(FakeClient, & &1.test)
      progress.("codex_session_started", %{session_id: "codex-#{claim["task_id"]}"})
      send(test, {:executing, claim["task_id"], self()})

      if claim["crash"], do: raise("executor crashed")

      if claim["block"] do
        receive do
          :finish -> :ok
        end
      end

      %{status: :completed}
    end
  end

  setup do
    test_pid = self()
    initial = fn -> %{test: test_pid, claims: [], claims_seen: [], events: [], heartbeats: [], outcomes: %{}} end
    start_supervised!(%{id: FakeClient, start: {Agent, :start_link, [initial, [name: FakeClient]]}})

    if is_nil(Process.whereis(SymphonyElixir.Worker.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: SymphonyElixir.Worker.TaskSupervisor})
    end

    root = Path.join(System.tmp_dir!(), "runtime-test-#{System.unique_integer([:positive])}")

    config = %Config{
      panel_url: "http://panel.test",
      registration_token: "token",
      worker_name: "worker",
      workspace_root: Path.join(root, "workspaces"),
      cache_root: Path.join(root, "cache"),
      log_root: Path.join(root, "logs"),
      client_module: FakeClient,
      executor_module: FakeExecutor,
      lifecycle_retry_seconds: 60,
      lifecycle_max_attempts: 3,
      executor_start_timeout_seconds: 60,
      image_reference: "worker:test",
      source_revision: "revision"
    }

    File.mkdir_p!(config.workspace_root)
    File.mkdir_p!(config.cache_root)
    File.mkdir_p!(config.log_root)
    %{config: config}
  end

  test "full slot reports zero and the next claim executes after terminal acknowledgement", %{config: config} do
    put_claims([claim("task-1", true), claim("task-2", false)])
    runtime = start_runtime(config)

    assert_receive {:executing, "task-1", executor}, 1_000
    send(runtime, :poll)
    send(runtime, :heartbeat)

    eventually(fn -> Enum.any?(state().claims_seen, &(&1["available_slots"] == 0)) end)
    eventually(fn -> Enum.any?(state().heartbeats, &(&1.available_slots == 0 and &1.active_leases == ["lease-task-1"])) end)

    send(executor, :finish)
    eventually(fn -> terminal_count("task-1") == 1 end)
    send(runtime, :poll)

    assert_receive {:executing, "task-2", _executor}, 1_000
    eventually(fn -> terminal_count("task-2") == 1 end)

    assert phases("task-1") == ["accepted", "execution_started", "codex_session_started"]
    assert phases("task-2") == ["accepted", "execution_started", "codex_session_started"]
  end

  test "terminal transport failure retains and renews the lease until retry succeeds", %{config: config} do
    Agent.update(FakeClient, fn state ->
      %{state | claims: [claim("task-1", false)], outcomes: %{"task.completed" => [{:error, :repo_unavailable}, {:ok, %{}}]}}
    end)

    runtime = start_runtime(config)
    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1") == 1 end)

    send(runtime, :heartbeat)
    eventually(fn -> Enum.any?(state().heartbeats, &(&1.active_leases == ["lease-task-1"])) end)

    send(runtime, {:retry_terminal, "task-1"})
    eventually(fn -> terminal_count("task-1") == 2 end)
    send(runtime, :heartbeat)
    eventually(fn -> Enum.any?(state().heartbeats, &(&1.active_leases == [])) end)
  end

  test "abnormal executor exit is delivered as task.failed", %{config: config} do
    put_claims([Map.put(claim("task-1", false), "crash", true)])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)
  end

  test "executor task startup failure is delivered as task.failed", %{config: config} do
    put_claims([claim("task-1", false)])
    config = %{config | task_supervisor: SymphonyElixir.Worker.MissingTaskSupervisor}

    runtime = start_runtime(config)

    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)
    assert Process.alive?(runtime)
    assert phases("task-1") == []
  end

  defp claim(task_id, block) do
    %{
      "task_id" => task_id,
      "lease_id" => "lease-#{task_id}",
      "project_id" => "project-1",
      "issue_id" => "issue-1",
      "run_id" => "run-1",
      "block" => block,
      "execution" => %{"issue" => %{"identifier" => "SYM-75"}}
    }
  end

  defp start_runtime(config) do
    start_supervised!(%{
      id: make_ref(),
      start: {GenServer, :start_link, [Runtime, config, []]}
    })
  end

  defp put_claims(claims), do: Agent.update(FakeClient, &%{&1 | claims: claims})
  defp state, do: Agent.get(FakeClient, & &1)
  defp terminal_count(task_id), do: terminal_count(task_id, "task.completed")

  defp terminal_count(task_id, terminal_type) do
    Enum.count(state().events, fn {id, type, _} -> id == task_id and type == terminal_type end)
  end

  defp phases(task_id) do
    Enum.flat_map(state().events, fn
      {^task_id, "task.accepted", payload} -> [payload.phase]
      {^task_id, "task.progress", payload} -> [payload.phase]
      _ -> []
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
