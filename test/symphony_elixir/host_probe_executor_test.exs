defmodule SymphonyElixir.HostProbeExecutorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.HostProbe.{HostClient, HostConfig, HostExecutor, HostRuntime}
  alias SymphonyElixir.RunFailure
  alias SymphonyElixir.Worker.ExecutionPayload
  alias SymphonyElixir.Worker.Runtime, as: WorkerRuntime

  defmodule HostLoopbackPanel do
    use Agent

    def start_host_loopback_panel(claim) do
      Agent.start_link(
        fn ->
          %{
            claim: claim,
            claimed?: false,
            accepted_truths: 0,
            heartbeat_count: 0,
            events: [],
            terminal_requests: 0,
            terminal_truths: %{}
          }
        end,
        name: __MODULE__
      )
    end

    def host_loopback_state, do: Agent.get(__MODULE__, & &1)
  end

  defmodule HostLoopbackTransport do
    import Plug.Conn

    def handle_host_request(conn) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      if get_req_header(conn, "authorization") == ["Bearer host-secret"] do
        dispatch_host_request(conn, payload)
      else
        send_host_json(conn, 401, %{error: %{code: "host_probe_unauthorized"}})
      end
    end

    defp dispatch_host_request(%{request_path: "/api/worker/v1/register"} = conn, _payload) do
      send_host_json(conn, 200, %{
        worker_id: "loopback-worker",
        session_id: "loopback-session",
        execution_surface: "host_probe",
        probe_id: "local-host",
        capability_digest: ExecutionRequirement.capability_digest([]),
        heartbeat_interval_seconds: 5,
        lease_duration_seconds: 30,
        accepted_protocol_version: "worker-api-v1"
      })
    end

    defp dispatch_host_request(%{request_path: "/api/worker/v1/tasks/claim"} = conn, _payload) do
      response =
        Agent.get_and_update(HostLoopbackPanel, fn
          %{claimed?: false} = state ->
            claim = state.claim
            {claim, %{state | claimed?: true, accepted_truths: 1}}

          state ->
            {%{"task" => nil, "poll_after_seconds" => 5}, state}
        end)

      send_host_json(conn, 200, response)
    end

    defp dispatch_host_request(%{request_path: "/api/worker/v1/heartbeat"} = conn, payload) do
      renewals =
        case payload["active_leases"] do
          [lease_id] -> [%{lease_id: lease_id, lease_expires_at: DateTime.utc_now() |> DateTime.add(30) |> DateTime.to_iso8601()}]
          [] -> []
        end

      Agent.update(HostLoopbackPanel, &Map.update!(&1, :heartbeat_count, fn count -> count + 1 end))
      send_host_json(conn, 200, %{lease_renewals: renewals, commands: []})
    end

    defp dispatch_host_request(%{request_path: path} = conn, %{"event_type" => type, "payload" => payload}) do
      task_id = path |> String.split("/") |> Enum.at(-2)

      status =
        Agent.get_and_update(HostLoopbackPanel, fn state ->
          event = %{task_id: task_id, type: type, payload: payload}
          record_host_event(state, event, type, payload)
        end)

      send_host_json(conn, status, %{accepted: status == 202, event_id: payload["event_id"]})
    end

    defp record_host_event(state, event, type, payload) do
      state = %{state | events: state.events ++ [event]}

      if type in ["task.completed", "task.failed", "task.cancelled"] do
        event_id = payload["event_id"]
        requests = state.terminal_requests + 1
        truths = Map.put_new(state.terminal_truths, event_id, event)
        response_status = if requests == 1, do: 503, else: 202
        {response_status, %{state | terminal_requests: requests, terminal_truths: truths}}
      else
        {202, state}
      end
    end

    defp send_host_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "host-probe-executor-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-182")
    File.mkdir_p!(workspace)
    token_file = Path.join(root, "token")
    File.write!(token_file, "host-secret")
    trace = Path.join(root, "codex-trace.jsonl")
    launcher = write_fake_host_codex!(root, trace)

    on_exit(fn -> File.rm_rf(root) end)

    config = %HostConfig{
      token_file: token_file,
      registration_token: "host-secret",
      workspace_root: root,
      launcher: "#{launcher} app-server",
      capabilities: [],
      capability_digest: ExecutionRequirement.capability_digest([]),
      source_revision: "host-probe-test"
    }

    %{config: config, root: root, workspace: workspace, trace: trace}
  end

  test "prepared execution uses the operator launcher and workspace without source or hook preparation", context do
    gate_marker = Path.join(context.root, "gate-cwd")
    claim = build_host_claim(context.root, "printf '%s' \"$PWD\" > #{gate_marker}")

    result = HostExecutor.execute_host_assignment(context.config, claim, fn _phase, _payload -> :ok end)

    assert result.status == :completed
    assert result.source.authority == "host_probe"
    assert result.source.prepared_head == "operator-prepared"
    assert result.validation.overall_status == :passed
    assert File.read!(gate_marker) == context.workspace
    assert File.exists?(Path.join(context.workspace, "panel-hook-ran")) == false

    turn_start =
      context.trace
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "turn/start"))

    assert get_in(turn_start, ["params", "cwd"]) == context.workspace

    thread_start =
      context.trace
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Enum.find(&(&1["method"] == "thread/start"))

    tool_names = get_in(thread_start, ["params", "dynamicTools"]) |> Enum.map(& &1["name"])
    assert "linear_task_read" in tool_names
    assert "create_pull_request" in tool_names
    assert "handoff" in tool_names
  end

  test "offline fixed-loopback runtime renews, gates, and replays one terminal truth", context do
    write_fake_host_codex!(context.root, context.trace, "sleep 1")
    gate_marker = Path.join(context.root, "loopback-gate")
    assignment = build_host_claim(context.root, "printf passed > #{gate_marker}")

    start_supervised!(%{
      id: HostLoopbackPanel,
      start: {HostLoopbackPanel, :start_host_loopback_panel, [assignment]}
    })

    if is_nil(Process.whereis(SymphonyElixir.HostProbe.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: SymphonyElixir.HostProbe.TaskSupervisor})
    end

    config = %{
      context.config
      | request_options: [plug: &HostLoopbackTransport.handle_host_request/1],
        lifecycle_retry_seconds: 60
    }

    runtime =
      start_supervised!(%{
        id: HostRuntime,
        start: {HostRuntime, :start_host_runtime_link, [config]}
      })

    eventually_host_executor(fn -> HostRuntime.read_host_runtime_state(runtime).active != nil end)
    first_generation = HostRuntime.read_host_runtime_state(runtime).active.deadline_generation

    send(runtime, :heartbeat)
    eventually_host_executor(fn -> HostLoopbackPanel.host_loopback_state().heartbeat_count == 1 end)

    eventually_host_executor(fn ->
      HostRuntime.read_host_runtime_state(runtime).active.deadline_generation == first_generation + 1
    end)

    eventually_host_executor(fn -> HostLoopbackPanel.host_loopback_state().terminal_requests == 1 end, 300)
    assert HostRuntime.read_host_runtime_state(runtime).active.phase == :delivering
    send(runtime, {:retry_terminal, "task-1"})
    eventually_host_executor(fn -> is_nil(HostRuntime.read_host_runtime_state(runtime).active) end)

    panel = HostLoopbackPanel.host_loopback_state()
    assert panel.accepted_truths == 1
    assert panel.terminal_requests == 2
    assert map_size(panel.terminal_truths) == 1
    assert [{event_id, terminal}] = Map.to_list(panel.terminal_truths)
    assert terminal.task_id == "task-1"
    assert terminal.type == "task.completed"
    assert terminal.payload["event_id"] == event_id
    assert terminal.payload["summary"]["validation_status"] == "passed"
    assert File.read!(gate_marker) == "passed"
    refute inspect(panel) =~ "host-secret"
  end

  test "missing launcher is environment unavailable before spawn", context do
    missing = %{context.config | launcher: "#{Path.join(context.root, "missing-codex")} app-server"}
    result = HostExecutor.execute_host_assignment(missing, build_host_claim(context.root), fn _phase, _payload -> :ok end)

    assert result.status == :failed
    assert result.reason == :workspace_unavailable
    assert result.failure_evidence == %{kind: "launcher_unavailable", stage: "pre_spawn"}
    assert File.exists?(context.trace) == false

    summary = WorkerRuntime.host_terminal_summary(result, missing, build_host_claim(context.root))
    assert RunFailure.from_worker_summary("task.failed", stringify_host_value(summary)).classification == "environment_unavailable"
  end

  test "spawned launcher exit is runtime failure", context do
    failing = Path.join(context.root, "failing-codex")
    File.write!(failing, "#!/bin/sh\nexit 23\n")
    File.chmod!(failing, 0o755)
    config = %{context.config | launcher: "#{failing} app-server"}
    claim = build_host_claim(context.root)

    {result, log} =
      with_log(fn -> HostExecutor.execute_host_assignment(config, claim, fn _phase, _payload -> :ok end) end)

    assert result.status == :failed
    assert result.reason == :failed
    refute log =~ context.root

    summary = WorkerRuntime.host_terminal_summary(result, config, claim)
    assert summary["reason"] == "worker_error"
    assert RunFailure.from_worker_summary("task.failed", stringify_host_value(summary)).classification == "runtime_failure"
  end

  test "fixed-root client sends bearer only in the header and returns typed transport failures", context do
    owner = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      response = %{
        worker_id: "worker-1",
        session_id: "session-1",
        execution_surface: "host_probe",
        probe_id: "local-host",
        capability_digest: context.config.capability_digest,
        heartbeat_interval_seconds: 5,
        lease_duration_seconds: 30,
        accepted_protocol_version: "worker-api-v1"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    config = %{context.config | request_options: [plug: plug]}
    assert {:ok, response} = HostClient.register_host_probe(config)
    assert response["worker_id"] == "worker-1"
    assert_receive {:request, "/api/worker/v1/register", headers, body}
    assert {"authorization", "Bearer host-secret"} in headers
    refute inspect(body) =~ "host-secret"
    assert config.panel_url == "http://127.0.0.1:4001"

    transport = %{
      config
      | request_options: [plug: fn conn -> Req.Test.transport_error(conn, :econnrefused) end]
    }

    assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
             HostClient.register_host_probe(transport)
  end

  defp build_host_claim(root, gate_command \\ "true") do
    %{
      "project_id" => "project-1",
      "task_id" => "task-1",
      "lease_id" => "lease-1",
      "issue_id" => "issue-1",
      "issue_identifier" => "SYM-182",
      "run_id" => "run-1",
      "run_attempt" => 0,
      "lease_attempt" => 1,
      "worker_id" => "worker-1",
      "session_id" => "session-1",
      "protocol_version" => "worker-api-v1",
      "execution" =>
        root
        |> build_host_panel_payload(gate_command)
        |> ExecutionPayload.from_task_payload()
    }
  end

  defp build_host_panel_payload(root, gate_command) do
    %{
      "issue" => %{"identifier" => "SYM-182", "title" => "Host probe", "description" => "Run prepared source."},
      "prompt" => "Complete the prepared task.",
      "workflow_profile" => "test",
      "execution_mode" => "worker",
      "source" => %{
        "repository" => root,
        "default_branch" => "main",
        "implementation_branch" => "vikingmew-sym-182",
        "source_strategy" => "clone",
        "checkout_depth" => 1
      },
      "hooks" => %{
        "after_create" => "printf hook > panel-hook-ran",
        "before_run" => nil,
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 10_000
      },
      "codex" => %{
        "command" => "false",
        "pre_start_commands" => ["exit 99"],
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "turn_sandbox_policy" => nil
      },
      "limits" => %{
        "initialize_timeout_ms" => 60_000,
        "turn_timeout_ms" => 10_000,
        "read_timeout_ms" => 5_000,
        "stall_timeout_ms" => 5_000
      },
      "required_gates" => [%{"name" => "prepared-gate", "command" => gate_command, "timeout_ms" => 10_000}],
      "handoff" => %{}
    }
  end

  defp write_fake_host_codex!(root, trace, turn_delay \\ "") do
    executable = Path.join(root, "fake-codex")

    File.write!(executable, """
    #!/bin/sh
    while IFS= read -r line; do
      printf '%s\n' "$line" >> #{trace}
      case "$line" in
        *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"host-thread"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"host-turn"}}}'
          #{turn_delay}
          printf '%s\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(executable, 0o755)
    executable
  end

  defp stringify_host_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), stringify_host_value(item)} end)
  defp stringify_host_value(value) when is_list(value), do: Enum.map(value, &stringify_host_value/1)
  defp stringify_host_value(value), do: value

  defp eventually_host_executor(fun, attempts \\ 100)
  defp eventually_host_executor(fun, 0), do: assert(fun.())

  defp eventually_host_executor(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually_host_executor(fun, attempts - 1)
    end
  end
end
