defmodule SymphonyElixir.OrchestratorOperatorTasksTest do
  use SymphonyElixir.TestSupport

  defmodule FakeAgentRunner do
    def run_operator(kind, run_id, recipient, opts) do
      parent = Application.fetch_env!(:symphony_elixir, :operator_runner_test_pid)
      send(parent, {:operator_runner_started, kind, run_id, self(), Keyword.get(opts, :worker_host)})

      receive do
        :emit_operator_updates ->
          send(recipient, {:worker_runtime_info, run_id, %{worker_host: Keyword.get(opts, :worker_host), workspace_path: "/tmp/operator/#{run_id}"}})

          send(recipient, {
            :codex_worker_update,
            run_id,
            %{
              event: :session_started,
              session_id: "thread-#{run_id}",
              codex_app_server_pid: "app-server-1",
              timestamp: DateTime.utc_now()
            }
          })

          wait_for_finish()

        {:finish_operator_runner, result} ->
          result
      after
        1_000 ->
          :ok
      end
    end

    def run(_issue, _recipient, _opts), do: :ok

    defp wait_for_finish do
      receive do
        {:finish_operator_runner, result} -> result
      after
        1_000 -> :ok
      end
    end
  end

  setup do
    previous_runner = Application.get_env(:symphony_elixir, :agent_runner_module)
    previous_pid = Application.get_env(:symphony_elixir, :operator_runner_test_pid)

    Application.put_env(:symphony_elixir, :agent_runner_module, FakeAgentRunner)
    Application.put_env(:symphony_elixir, :operator_runner_test_pid, self())

    on_exit(fn ->
      restore_app_env(:agent_runner_module, previous_runner)
      restore_app_env(:operator_runner_test_pid, previous_pid)
    end)

    :ok
  end

  test "requesting nap starts a real monitored operator process and records runtime updates" do
    {:ok, pid} = start_operator_orchestrator(:RealNap)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    assert reply.status == "running"
    run_id = reply.run_id

    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500

    state = :sys.get_state(pid)
    assert %{^run_id => running_entry} = state.running
    assert is_pid(running_entry.pid)
    assert Process.alive?(running_entry.pid)
    assert is_reference(running_entry.ref)
    assert running_entry.kind == "nap"

    send(runner_pid, :emit_operator_updates)

    snapshot =
      wait_for_snapshot(pid, fn
        %{running: [%{workspace_path: workspace_path, session_id: session_id}]} ->
          workspace_path == "/tmp/operator/#{run_id}" and session_id == "thread-#{run_id}"

        _ ->
          false
      end)

    assert [%{codex_app_server_pid: "app-server-1", turn_count: 1}] = snapshot.running

    send(runner_pid, {:finish_operator_runner, :ok})

    completed =
      wait_for_snapshot(pid, fn snapshot ->
        snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "completed"
      end)

    assert completed.operator_tasks.nap.run_id == run_id
  end

  test "operator runner failures clear running state and mark the task failed" do
    {:ok, pid} = start_operator_orchestrator(:FailedNap)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    run_id = reply.run_id
    assert_receive {:operator_runner_started, :nap, ^run_id, runner_pid, _worker_host}, 500

    send(runner_pid, {:finish_operator_runner, {:error, {:codex_startup_failed, %{reason: :boom}}}})

    snapshot =
      wait_for_snapshot(pid, fn snapshot ->
        snapshot.running == [] and get_in(snapshot, [:operator_tasks, :nap, :status]) == "failed"
      end)

    assert snapshot.operator_tasks.nap.failure_reason =~ "codex_startup_failed"
  end

  test "stale synthetic operator entries do not keep the runtime busy forever" do
    {:ok, pid} = start_operator_orchestrator(:StaleOperator)

    stale_run_id = "operator-nap-stale"

    :sys.replace_state(pid, fn state ->
      stale_entry = %{
        kind: "nap",
        profile: "nap",
        label: "Nap",
        pid: nil,
        ref: nil,
        run_id: stale_run_id,
        identifier: nil,
        issue_id: nil,
        issue: nil,
        state: "running",
        worker_host: "local",
        workspace_path: nil,
        session_id: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: "operator_task.started",
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0,
        retry_attempt: 0,
        started_at: DateTime.utc_now(),
        session_history: [],
        session_history_total_count: 0
      }

      %{state | running: %{stale_run_id => stale_entry}}
    end)

    reply = GenServer.call(pid, {:request_operator_task, :day_dreaming})
    assert reply.status == "running"

    assert_receive {:operator_runner_started, :day_dreaming, run_id, runner_pid, _worker_host}, 500
    refute run_id == stale_run_id

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, stale_run_id)
    assert Map.has_key?(state.running, run_id)

    send(runner_pid, {:finish_operator_runner, :ok})
  end

  test "rate-limit gate queues operator work instead of starting a session" do
    {:ok, pid} = start_operator_orchestrator(:RateLimitBlockedOperator)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | codex_rate_limits: %{
            "primary" => %{
              "window_duration_mins" => 300,
              "used_percent" => 99,
              "resets_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()
            }
          }
      }
    end)

    reply = GenServer.call(pid, {:request_operator_task, :nap})
    assert reply.status == "queued"
    refute_receive {:operator_runner_started, :nap, _run_id, _runner_pid, _worker_host}, 100

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.running == []
    assert snapshot.rate_limit_gate.status == :blocked
    assert snapshot.operator_tasks.nap.status == "queued"
  end

  defp start_operator_orchestrator(suffix) do
    orchestrator_name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    {:ok, pid}
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 500) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
