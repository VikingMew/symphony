defmodule SymphonyElixir.Worker.RuntimeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Worker.{Config, Runtime}
  alias SymphonyElixir.WorkerResult

  defmodule FakeClient do
    def protocol_version, do: "worker-api-v1"

    def register(_config) do
      {:ok, %{"worker_id" => "worker-1", "session_id" => "session-1", "heartbeat_interval_seconds" => 60}}
    end

    def claim(_config, request), do: Agent.get_and_update(__MODULE__, &pop_claim(&1, request))

    def heartbeat(_config, _identity, payload) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = {:ok, %{"commands" => state.commands}}
        state = %{state | commands: [], heartbeats: [payload | state.heartbeats]}
        {response, state}
      end)
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
      {{:ok, %{"task" => nil, "poll_after_seconds" => 60}}, %{state | claims_seen: state.claims_seen ++ [request]}}
    end

    defp pop_claim(%{claims: [{:error, _reason} = error | claims]} = state, request),
      do: {error, %{state | claims: claims, claims_seen: state.claims_seen ++ [request]}}

    defp pop_claim(%{claims: [claim | claims]} = state, request),
      do: {{:ok, claim}, %{state | claims: claims, claims_seen: state.claims_seen ++ [request]}}

    defp pop_claim(state, request), do: {{:ok, %{"task" => nil}}, %{state | claims_seen: state.claims_seen ++ [request]}}
    defp pop_outcome([outcome | rest]), do: {outcome, rest}
    defp pop_outcome([]), do: {{:ok, %{}}, []}
  end

  defmodule FakeExecutor do
    def execute(_config, claim, progress) do
      test = Agent.get(FakeClient, & &1.test)
      progress.("codex_session_started", %{session_id: "codex-#{claim["task_id"]}"})
      if tokens = claim["codex_tokens"], do: progress.("codex_update", %{codex: codex_token_update(claim, tokens)})
      send(test, {:executing, claim["task_id"], self()})

      if claim["crash"], do: raise("executor crashed")

      wait_for_claim_mode(claim, test)
      claim_result(claim)
    end

    defp wait_for_claim_mode(%{"trap_shutdown" => true} = claim, test) do
      Process.flag(:trap_exit, true)

      receive do
        {:EXIT, _from, :shutdown} ->
          send(test, {:shutdown_received, claim["task_id"], self()})

          receive do
            :finish -> :ok
          end
      end
    end

    defp wait_for_claim_mode(%{"block" => true}, _test) do
      receive do
        :finish -> :ok
      end
    end

    defp wait_for_claim_mode(_claim, _test), do: :ok

    defp claim_result(%{"trap_shutdown" => true}), do: %{status: :cancelled}

    defp claim_result(%{"validation_result" => validation}) do
      %{status: :failed, phase: :validation, validation: validation}
    end

    defp claim_result(%{"failed_reason" => reason, "failed_detail" => detail}) do
      %{
        status: :failed,
        reason: reason,
        detail: detail
      }
    end

    defp claim_result(%{"failed_reason" => reason}), do: %{status: :failed, reason: reason}

    defp claim_result(%{"blocked" => true}) do
      %{
        status: :blocked,
        reason: {:handoff_failed, {:push_permission_blocked, "workflow scope"}},
        detail: "workflow scope"
      }
    end

    defp claim_result(_claim), do: %{status: :completed, validation: %{overall_status: :passed, gates: []}}

    defp codex_token_update(claim, tokens) do
      %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        session_id: "codex-#{claim["task_id"]}",
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "total" => tokens
            }
          }
        }
      }
    end
  end

  setup do
    test_pid = self()

    initial = fn ->
      %{test: test_pid, claims: [], claims_seen: [], commands: [], events: [], heartbeats: [], outcomes: %{}}
    end

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

  test "codex token progress is delivered as task progress", %{config: config} do
    put_claims([
      Map.put(claim("task-1", false), "codex_tokens", %{
        "input_tokens" => 4,
        "output_tokens" => 6,
        "total_tokens" => 10
      })
    ])

    _runtime = start_runtime(config)
    assert_receive {:executing, "task-1", _executor}, 1_000

    eventually(fn ->
      Enum.any?(state().events, fn
        {"task-1", "task.progress",
         %{
           phase: "codex_update",
           codex: %{
             event: :notification,
             payload: %{
               "method" => "thread/tokenUsage/updated",
               "params" => %{"tokenUsage" => %{"total" => %{"total_tokens" => 10}}}
             }
           }
         }} ->
          true

        _event ->
          false
      end)
    end)
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

  test "generic executor failure reports pending validation and required gates as not run", %{config: config} do
    failed_claim =
      claim("task-1", false)
      |> Map.put("failed_reason", :failed)
      |> Map.put("failed_detail", "executor failed")
      |> put_required_gates([
        %{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120},
        %{"name" => "unit", "command" => "scripts/unit.sh", "timeout_seconds" => 300}
      ])

    put_claims([failed_claim])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["outcome"] == "failed"
    assert summary["reason"] == "worker_error"
    assert summary["validation_status"] == "pending"
    assert Enum.map(summary["gates"], & &1["status"]) == ["not_run", "not_run"]
    assert Enum.map(summary["gates"], & &1["name"]) == ["check", "unit"]
    assert Jason.decode!(summary["detail"]) == %{"detail" => "executor failed", "reason" => "failed", "status" => "failed"}
    assert {:ok, _validated} = WorkerResult.validate(summary)
  end

  test "validation failure preserves executed gate evidence", %{config: config} do
    gate = %{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}

    validation = %{
      overall_status: :failed,
      gates: [%{command: gate["command"], status: :failed, exit_code: 1, duration_ms: 42, detail: "format error"}]
    }

    failed_claim = claim("task-1", false) |> Map.put("validation_result", validation) |> put_required_gates([gate])
    put_claims([failed_claim])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["reason"] == "non_zero"
    assert summary["validation_status"] == "failed"

    assert summary["gates"] == [
             %{
               "name" => "check",
               "status" => "failed",
               "exit_code" => 1,
               "duration_ms" => 42,
               "timeout_ms" => 120_000,
               "failure_detail" => "format error"
             }
           ]

    assert {:ok, _validated} = WorkerResult.validate(summary)
  end

  test "missing implementation handoff reports pre-validation gate evidence and JSON detail", %{config: config} do
    failed_claim =
      claim("task-1", false)
      |> Map.put("failed_reason", {:handoff_failed, :missing_handoff})
      |> put_required_gates([%{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}])

    put_claims([failed_claim])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["reason"] == "handoff_failed"
    assert summary["validation_status"] == "pending"
    assert [%{"name" => "check", "status" => "not_run"}] = summary["gates"]

    assert Jason.decode!(summary["detail"]) == %{
             "reason" => ["handoff_failed", "missing_handoff"],
             "status" => "failed"
           }

    refute summary["detail"] =~ "%{"
    refute summary["detail"] =~ "status: :failed"
    assert {:ok, _validated} = WorkerResult.validate(summary)
  end

  test "blocked executor outcome is delivered as task.failed with an explicit blocked summary", %{config: config} do
    blocked_claim =
      claim("task-1", false)
      |> Map.put("blocked", true)
      |> put_required_gates([%{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}])

    put_claims([blocked_claim])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    assert [{"task-1", "task.failed", %{summary: summary}}] =
             Enum.filter(state().events, fn {id, type, _payload} ->
               id == "task-1" and type == "task.failed"
             end)

    assert summary["outcome"] == "blocked"
    assert summary["reason"] == "handoff_failed"
    assert summary["validation_status"] == "pending"
    assert [%{"name" => "check", "status" => "not_run"}] = summary["gates"]
    assert summary["detail"] =~ "push_permission_blocked"
  end

  test "execution capability failures are delivered as task.failed with a typed summary reason", %{config: config} do
    put_claims([
      claim("task-1", false)
      |> Map.put("failed_reason", :execution_capability_unavailable)
      |> Map.put("failed_detail", "bwrap: No permissions to create a new namespace")
    ])

    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    assert [{"task-1", "task.failed", %{summary: summary}}] =
             Enum.filter(state().events, fn {id, type, _payload} ->
               id == "task-1" and type == "task.failed"
             end)

    assert summary["outcome"] == "failed"
    assert summary["reason"] == "execution_capability_unavailable"
    assert summary["detail"] =~ "bwrap: No permissions to create a new namespace"
  end

  test "cancel command stops executor, emits evidence, and stops renewing the lease", %{config: config} do
    cancelled_claim =
      claim("task-1", false)
      |> Map.put("trap_shutdown", true)
      |> put_required_gates([%{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}])

    put_claims([cancelled_claim])
    runtime = start_runtime(config)

    assert_receive {:executing, "task-1", executor}, 1_000
    put_commands([%{"type" => "cancel_task", "task_id" => "task-1", "reason" => "operator"}])
    send(runtime, :heartbeat)

    assert_receive {:shutdown_received, "task-1", ^executor}, 1_000
    eventually(fn -> "cancelling" in phases("task-1") end)

    send(runtime, :heartbeat)
    eventually(fn -> Enum.any?(state().heartbeats, &(&1.active_leases == [])) end)

    send(executor, :finish)
    eventually(fn -> terminal_count("task-1", "task.cancelled") == 1 end)

    summary = terminal_summary("task-1", "task.cancelled")
    assert summary["validation_status"] == "pending"
    assert [%{"name" => "check", "status" => "not_run"}] = summary["gates"]

    send(runtime, {:retry_terminal, "task-1"})
    Process.sleep(20)
    assert terminal_count("task-1", "task.cancelled") == 1
  end

  test "executor task startup failure is delivered as task.failed", %{config: config} do
    put_claims([claim("task-1", false)])
    config = %{config | task_supervisor: SymphonyElixir.Worker.MissingTaskSupervisor}

    runtime = start_runtime(config)

    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)
    assert Process.alive?(runtime)
    assert phases("task-1") == []
  end

  test "empty claim advice is observed with a legacy fallback", %{config: config} do
    put_claims([%{"task" => nil, "poll_after_seconds" => 30}, %{"task" => nil}])
    runtime = start_runtime(config)

    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 30 end)
    send(runtime, :poll)
    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 5 end)
    assert :sys.get_state(runtime).claim_http_failure_streak == 0
  end

  test "claim HTTP failures back off to sixty seconds and success resets the streak", %{config: config} do
    put_claims([
      {:error, {:http_error, 429, %{}}},
      {:error, {:http_error, 503, %{}}},
      %{"task" => nil, "poll_after_seconds" => 5},
      {:error, {:http_error, 500, %{}}}
    ])

    runtime = start_runtime(config)
    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 30 end)
    send(runtime, :poll)
    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 60 end)
    send(runtime, :poll)
    eventually(fn -> :sys.get_state(runtime).claim_http_failure_streak == 0 end)
    send(runtime, :poll)
    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 30 end)
  end

  defp claim(task_id, block) do
    %{
      "task_id" => task_id,
      "lease_id" => "lease-#{task_id}",
      "project_id" => "project-1",
      "issue_id" => "issue-1",
      "run_id" => "run-1",
      "block" => block,
      "execution" => %{"issue" => %{"identifier" => "SYM-75"}, "required_gates" => []}
    }
  end

  defp put_required_gates(claim, gates), do: put_in(claim, ["execution", "required_gates"], gates)

  defp start_runtime(config) do
    start_supervised!(%{
      id: make_ref(),
      start: {GenServer, :start_link, [Runtime, config, []]}
    })
  end

  defp put_claims(claims), do: Agent.update(FakeClient, &%{&1 | claims: claims})
  defp put_commands(commands), do: Agent.update(FakeClient, &%{&1 | commands: commands})

  defp state, do: Agent.get(FakeClient, & &1)
  defp terminal_count(task_id), do: terminal_count(task_id, "task.completed")

  defp terminal_count(task_id, terminal_type) do
    Enum.count(state().events, fn {id, type, _} -> id == task_id and type == terminal_type end)
  end

  defp terminal_summary(task_id, terminal_type) do
    [{^task_id, ^terminal_type, %{summary: summary}}] =
      Enum.filter(state().events, fn {id, type, _payload} -> id == task_id and type == terminal_type end)

    summary
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
