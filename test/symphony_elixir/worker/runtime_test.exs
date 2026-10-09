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

      if claim["source_progress"] do
        progress.("source_preparation", %{
          source: "worker",
          operation: "git_clone",
          status: "output",
          detail: "Receiving objects: 10%"
        })
      end

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
      if validation[:status], do: validation, else: %{status: :failed, phase: :validation, validation: validation}
    end

    defp claim_result(%{"failed_reason" => reason, "failed_detail" => detail}) do
      %{
        status: :failed,
        reason: reason,
        detail: detail
      }
    end

    defp claim_result(%{"failed_reason" => reason}), do: %{status: :failed, reason: reason}

    defp claim_result(%{"source_timeout" => true}) do
      %{
        status: :failed,
        reason: :source_preparation_timeout,
        detail: "waiting for remote source",
        failure_evidence: %{
          phase: "clone_failed",
          command_status: "timed_out",
          duration_ms: 1_002,
          output: "waiting for remote source"
        }
      }
    end

    defp claim_result(%{"blocked_validation_failed" => true}) do
      evidence = %{"marker" => "需宿主 push", "patch_path" => "SYM-110.patch"}

      %{
        status: :blocked,
        reason: {:handoff_failed, {:host_push_required, evidence}},
        detail: evidence,
        validation: %{
          overall_status: :failed,
          gates: [%{status: :failed, exit_code: 7, duration_ms: 42, detail: "validation failed"}]
        }
      }
    end

    defp claim_result(%{"blocked" => true}) do
      evidence = %{"marker" => "需宿主 push", "patch_path" => "SYM-110.patch"}

      %{
        status: :blocked,
        reason: {:handoff_failed, {:host_push_required, evidence}},
        detail: evidence,
        validation: %{
          overall_status: :passed,
          gates: [%{status: :passed, exit_code: 0, duration_ms: 42, detail: ""}]
        }
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

  test "runtime is the sole writer of the source progress phase", %{config: config} do
    put_claims([Map.put(claim("task-1", false), "source_progress", true)])
    _runtime = start_runtime(config)
    assert_receive {:executing, "task-1", _executor}, 1_000

    eventually(fn ->
      Enum.any?(state().events, fn
        {"task-1", "task.progress",
         %{
           phase: "source_preparation",
           source: "worker",
           operation: "git_clone",
           status: "output"
         } = payload} ->
          Map.has_key?(payload, "phase") == false

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

  test "terminal delivery remains pending after the configured attempt limit and recovers", %{config: config} do
    Agent.update(FakeClient, fn state ->
      outcomes = [
        {:error, {:http_error, 503, "unavailable"}},
        {:error, {:http_error, 503, "unavailable"}},
        {:error, {:http_error, 503, "unavailable"}},
        {:ok, %{}}
      ]

      %{state | claims: [claim("task-1", false)], outcomes: %{"task.completed" => outcomes}}
    end)

    runtime = start_runtime(config)
    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1") == 1 end)

    send(runtime, {:retry_terminal, "task-1"})
    eventually(fn -> terminal_count("task-1") == 2 end)
    send(runtime, {:retry_terminal, "task-1"})
    eventually(fn -> terminal_count("task-1") == 3 end)

    send(runtime, :heartbeat)
    eventually(fn -> Enum.any?(state().heartbeats, &(&1.active_leases == ["lease-task-1"])) end)

    send(runtime, {:retry_terminal, "task-1"})
    eventually(fn -> terminal_count("task-1") == 4 end)
    ids = for {"task-1", "task.completed", payload} <- state().events, do: payload["event_id"]
    assert [id] = Enum.uniq(ids)
    assert {:ok, ^id} = Ecto.UUID.cast(id)

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
    assert Jason.decode!(summary["detail"]) == %{"reason" => "failed", "status" => "failed"}
    assert {:ok, _validated} = WorkerResult.validate(summary)
  end

  test "failed Codex completions emit only typed task.failed summaries before validation", %{config: config} do
    gates = [
      %{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120},
      %{"name" => "unit", "command" => "scripts/unit.sh", "timeout_seconds" => 300}
    ]

    capacity =
      claim("capacity", false)
      |> Map.put("failed_reason", :codex_upstream_capacity)
      |> Map.put("failed_detail", %{
        "codex_error_info" => "serverOverloaded",
        "turn_status" => "failed",
        "will_retry" => false
      })
      |> put_required_gates(gates)

    generic =
      claim("generic", false)
      |> Map.put("failed_reason", :codex_turn_failed)
      |> Map.put("failed_detail", %{"turn_status" => "failed"})
      |> put_required_gates(gates)

    put_claims([capacity, generic])
    runtime = start_runtime(config)

    assert_receive {:executing, "capacity", _executor}, 1_000
    eventually(fn -> terminal_count("capacity", "task.failed") == 1 end)
    send(runtime, :poll)
    assert_receive {:executing, "generic", _executor}, 1_000
    eventually(fn -> terminal_count("generic", "task.failed") == 1 end)

    for {task_id, reason} <- [
          {"capacity", "codex_upstream_capacity"},
          {"generic", "codex_turn_failed"}
        ] do
      summary = terminal_summary(task_id, "task.failed")
      assert summary["phase"] == "codex"
      assert summary["outcome"] == "failed"
      assert summary["reason"] == reason
      assert summary["validation_status"] == "pending"
      assert Enum.map(summary["gates"], & &1["status"]) == ["not_run", "not_run"]
      assert terminal_count(task_id, "task.completed") == 0
      assert {:ok, _validated} = WorkerResult.validate(summary)
    end

    assert Jason.decode!(terminal_summary("capacity", "task.failed")["detail"]) == %{
             "reason" => "codex_upstream_capacity",
             "status" => "failed"
           }
  end

  test "source timeout delivers task.failed with structured command evidence", %{config: config} do
    put_claims([Map.put(claim("task-1", false), "source_timeout", true)])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["phase"] == "source_preparation"
    assert summary["reason"] == "source_preparation_timeout"

    assert summary["failure_evidence"] == %{
             phase: "clone_failed",
             command_status: "timed_out",
             duration_ms: 1_002,
             output: "waiting for remote source"
           }

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

  test "validation failure normalizes paths before bounding terminal gate evidence", %{config: config} do
    gate = %{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}
    limit = WorkerResult.limits().max_detail

    details = [
      {"unix", "command=scripts/check.sh failed at /tmp/worker/output.log"},
      {"windows", "command=scripts/check.sh failed at C:\\worker\\output.log"},
      {"oversized",
       "command=scripts/check.sh HEAD /tmp/worker/output.log " <>
         String.duplicate("中", limit) <>
         " TAIL"}
    ]

    claims =
      Enum.map(details, fn {task_id, detail} ->
        validation = %{
          overall_status: :failed,
          gates: [%{command: gate["command"], status: :failed, exit_code: 7, duration_ms: 42, detail: detail}]
        }

        claim(task_id, false) |> Map.put("validation_result", validation) |> put_required_gates([gate])
      end)

    put_claims(claims)
    runtime = start_runtime(config)

    Enum.each(details, fn {task_id, raw_detail} ->
      assert_receive {:executing, ^task_id, _executor}, 1_000
      eventually(fn -> terminal_count(task_id, "task.failed") == 1 end)
      summary = terminal_summary(task_id, "task.failed")
      [gate_summary] = summary["gates"]

      assert gate_summary["name"] == "check"
      assert gate_summary["status"] == "failed"
      assert gate_summary["exit_code"] == 7
      assert gate_summary["failure_detail"] =~ "command=scripts/check.sh"
      assert gate_summary["failure_detail"] =~ "[worker-local path]"
      refute gate_summary["failure_detail"] =~ raw_detail
      refute summary["detail"] =~ "/tmp/worker"
      refute summary["detail"] =~ "C:\\worker"
      assert {:ok, _validated} = WorkerResult.validate(summary)

      if task_id == "oversized" do
        assert String.length(gate_summary["failure_detail"]) == limit
        assert gate_summary["failure_detail"] =~ "... (truncated) ..."
        assert String.ends_with?(gate_summary["failure_detail"], " TAIL")
      end

      send(runtime, :poll)
    end)
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
    assert summary["validation_status"] == "passed"
    assert [%{"name" => "check", "status" => "passed"}] = summary["gates"]

    assert Jason.decode!(summary["detail"]) == %{
             "reason" => [
               "handoff_failed",
               ["host_push_required", %{"marker" => "需宿主 push", "patch_path" => "SYM-110.patch"}]
             ],
             "status" => "blocked"
           }
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

    assert Jason.decode!(summary["detail"]) == %{
             "reason" => "execution_capability_unavailable",
             "status" => "failed"
           }
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
    :sys.get_state(runtime)
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

  test "service claim advice controls cadence without per-issue worker state", %{config: config} do
    put_claims([%{"task" => nil, "poll_after_seconds" => 30}, %{"task" => nil}])
    runtime = start_runtime(config)

    eventually(fn -> :sys.get_state(runtime).next_poll_seconds == 30 end)

    assert [request | _rest] = state().claims_seen

    assert request == %{
             "worker_id" => "worker-1",
             "session_id" => "session-1",
             "protocol_version" => "worker-api-v1",
             "available_slots" => 1,
             "capabilities" => %{"execution" => ["v1"]}
           }

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

  test "blocked host-push outcome preserves failed validation evidence", %{config: config} do
    blocked_claim =
      claim("task-1", false)
      |> Map.put("blocked_validation_failed", true)
      |> put_required_gates([%{"name" => "check", "command" => "scripts/check.sh", "timeout_seconds" => 120}])

    put_claims([blocked_claim])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["outcome"] == "blocked"
    assert summary["reason"] == "handoff_failed"
    assert summary["validation_status"] == "failed"

    assert [%{"name" => "check", "status" => "failed", "exit_code" => 7, "failure_detail" => "validation failed"}] =
             summary["gates"]

    assert {:ok, _validated} = WorkerResult.validate(summary)
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

  test "non-timeout source failure retains the closed terminal contract", %{config: config} do
    result = %{
      status: :failed,
      reason: :source_preparation_failed,
      detail: "merge conflict",
      failure_evidence: %{
        phase: "checkout_failed",
        command_status: "failed",
        operation: "task_branch_merge",
        detail: "merge conflict"
      }
    }

    put_claims([Map.put(claim("task-1", false), "validation_result", result)])
    _runtime = start_runtime(config)

    assert_receive {:executing, "task-1", _executor}, 1_000
    eventually(fn -> terminal_count("task-1", "task.failed") == 1 end)

    summary = terminal_summary("task-1", "task.failed")
    assert summary["phase"] == "source_preparation"
    assert summary["reason"] == "source_preparation_failed"
    assert summary["failure_evidence"].phase == "checkout_failed"
    assert {:ok, _validated} = WorkerResult.validate(summary)
  end
end
