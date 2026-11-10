defmodule SymphonyElixir.HostProbeRuntimeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.HostProbe.{HostConfig, HostLauncher, HostRuntime, HostWorkspace}

  defmodule HostRuntimeFixture do
    use Agent

    def start_host_runtime_fixture(test), do: Agent.start_link(fn -> initial_host_fixture_state(test) end, name: __MODULE__)
    def put_host_fixture(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
    def host_fixture_state, do: Agent.get(__MODULE__, & &1)

    def handle_host_fixture_request(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      {status, response} = host_fixture_response(conn.request_path, payload)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end

    defp host_fixture_response("/api/worker/v1/register", _payload) do
      {200,
       %{
         worker_id: "host-worker",
         session_id: "host-session",
         execution_surface: "host_probe",
         probe_id: "local-host",
         capability_digest: ExecutionRequirement.capability_digest([]),
         heartbeat_interval_seconds: 60,
         lease_duration_seconds: 30,
         accepted_protocol_version: "worker-api-v1"
       }}
    end

    defp host_fixture_response("/api/worker/v1/tasks/claim", payload) do
      response =
        Agent.get_and_update(__MODULE__, fn state ->
          case state.claims do
            [claim | rest] -> {claim, %{state | claims: rest, claim_requests: [payload | state.claim_requests]}}
            [] -> {%{"task" => nil, "poll_after_seconds" => 60}, state}
          end
        end)

      {200, response}
    end

    defp host_fixture_response("/api/worker/v1/heartbeat", payload) do
      response =
        Agent.get_and_update(__MODULE__, fn state ->
          response = List.first(state.heartbeats) || %{"lease_renewals" => [], "commands" => []}
          rest = if state.heartbeats == [], do: [], else: tl(state.heartbeats)
          {response, %{state | heartbeats: rest, heartbeat_requests: [payload | state.heartbeat_requests]}}
        end)

      {200, response}
    end

    defp host_fixture_response(path, %{"event_type" => event_type, "payload" => payload}) do
      task_id = path |> String.split("/") |> Enum.at(-2)

      Agent.get_and_update(__MODULE__, fn state ->
        event = %{task_id: task_id, type: event_type, payload: payload}
        terminal? = event_type in ["task.completed", "task.failed", "task.cancelled"]

        case {terminal?, state.terminal_outcomes} do
          {true, [outcome | rest]} ->
            {status, body} = host_fixture_outcome(outcome)
            {{status, body}, %{state | terminal_outcomes: rest, events: state.events ++ [event]}}

          _other ->
            {{202, %{accepted: true}}, %{state | events: state.events ++ [event]}}
        end
      end)
    end

    defp host_fixture_outcome({:ok, body}), do: {202, body}
    defp host_fixture_outcome({:error, {:transport_error, _reason}}), do: {503, %{error: "transport"}}
    defp host_fixture_outcome({:error, {:http_error, status, body}}), do: {status, body}

    defp initial_host_fixture_state(test) do
      %{
        test: test,
        claims: [],
        claim_requests: [],
        heartbeats: [],
        heartbeat_requests: [],
        terminal_outcomes: [],
        events: []
      }
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "host-probe-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    token_file = Path.join(root, "token")
    File.write!(token_file, "host-secret\n")
    File.chmod!(token_file, 0o644)

    test = self()

    start_supervised!(%{
      id: HostRuntimeFixture,
      start: {HostRuntimeFixture, :start_host_runtime_fixture, [test]}
    })

    if is_nil(Process.whereis(SymphonyElixir.HostProbe.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: SymphonyElixir.HostProbe.TaskSupervisor})
    end

    on_exit(fn -> File.rm_rf(root) end)

    config = %HostConfig{
      token_file: token_file,
      registration_token: "host-secret",
      workspace_root: root,
      launcher: "codex app-server",
      capabilities: [],
      capability_digest: ExecutionRequirement.capability_digest([]),
      heartbeat_seconds: 60,
      request_options: [plug: &HostRuntimeFixture.handle_host_fixture_request/1],
      execute_assignment: fn _config, claim, _progress ->
        send(test, {:executor_started, claim["task_id"], self()})

        case claim["mode"] do
          "block" ->
            receive do
              :finish -> %{status: :completed, validation: %{overall_status: :passed, gates: []}}
            end

          "crash" ->
            raise "post-spawn failure"

          _other ->
            %{status: :completed, validation: %{overall_status: :passed, gates: []}}
        end
      end,
      lifecycle_retry_seconds: 60,
      source_revision: "test-revision"
    }

    %{root: root, token_file: token_file, config: config}
  end

  test "token loading accepts operator-selected file permissions and keeps the Panel root fixed", context do
    Application.put_env(:symphony_elixir, :host_probe,
      token_file: context.token_file,
      workspace_root: context.root,
      launcher: "codex app-server",
      capabilities: []
    )

    on_exit(fn -> Application.delete_env(:symphony_elixir, :host_probe) end)

    loaded = HostConfig.load_host_config!()
    assert loaded.registration_token == "host-secret"
    assert loaded.panel_url == "http://127.0.0.1:4001"
    assert File.stat!(context.token_file).mode |> Bitwise.band(0o777) == 0o644
  end

  test "prepared workspace accepts only the expected contained readable and writable directory", %{root: root} do
    workspace = Path.join(root, "SYM-182")
    File.mkdir_p!(workspace)

    assert {:ok, ^workspace} = HostWorkspace.resolve_host_workspace(root, "SYM-182")
    assert {:error, %{kind: "workspace_missing", stage: "workspace_preflight"}} = HostWorkspace.resolve_host_workspace(root, "SYM-404")

    file = Path.join(root, "SYM-FILE")
    File.write!(file, "not a directory")
    assert {:error, %{kind: "workspace_not_directory"}} = HostWorkspace.resolve_host_workspace(root, "SYM-FILE")

    assert {:error, %{kind: "workspace_escape"} = escape} = HostWorkspace.resolve_host_workspace(root, "../escape")
    refute inspect(escape) =~ root

    assert {:error, %{kind: "workspace_unreadable"}} =
             HostWorkspace.resolve_host_workspace(root, "SYM-182", list: fn _path -> {:error, :eacces} end)

    assert {:error, %{kind: "workspace_not_writable"}} =
             HostWorkspace.resolve_host_workspace(root, "SYM-182", write_probe: fn _path -> {:error, :erofs} end)
  end

  test "workspace rejects a symlink that resolves outside the configured root", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "host-probe-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "SYM-LINK"))
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, %{kind: "workspace_escape", stage: "workspace_preflight"}} =
             HostWorkspace.resolve_host_workspace(root, "SYM-LINK")
  end

  test "launcher preflight distinguishes absence before any child process exists" do
    assert {:error, %{kind: "launcher_unavailable", stage: "pre_spawn"}} =
             HostLauncher.preflight_host_launcher("missing-codex app-server", fn _executable -> nil end)

    assert :ok = HostLauncher.preflight_host_launcher("operator-codex app-server", fn "operator-codex" -> "/operator/codex" end)
  end

  test "only a matching explicit renewal extends the local deadline", %{config: config} do
    HostRuntimeFixture.put_host_fixture(:claims, [host_runtime_claim("task-renewal", "block")])

    HostRuntimeFixture.put_host_fixture(:heartbeats, [
      %{"lease_renewals" => [], "commands" => []},
      %{"lease_renewals" => [%{"lease_id" => "lease-task-renewal"}], "commands" => []}
    ])

    runtime = start_supervised!(%{id: HostRuntime, start: {HostRuntime, :start_host_runtime_link, [config]}})
    assert_receive {:executor_started, "task-renewal", _executor}, 1_000
    first = HostRuntime.read_host_runtime_state(runtime).active.deadline_generation

    send(runtime, :heartbeat)
    eventually_host_runtime(fn -> length(HostRuntimeFixture.host_fixture_state().heartbeat_requests) == 1 end)
    assert HostRuntime.read_host_runtime_state(runtime).active.deadline_generation == first

    send(runtime, :heartbeat)
    eventually_host_runtime(fn -> length(HostRuntimeFixture.host_fixture_state().heartbeat_requests) == 2 end)
    assert HostRuntime.read_host_runtime_state(runtime).active.deadline_generation == first + 1
  end

  test "local expiry stops execution and replays one stable terminal event after a lost acknowledgement", %{config: config} do
    HostRuntimeFixture.put_host_fixture(:claims, [host_runtime_claim("task-expiry", "block")])

    HostRuntimeFixture.put_host_fixture(:terminal_outcomes, [
      {:error, {:transport_error, :closed}},
      {:ok, %{"accepted" => true}}
    ])

    runtime = start_supervised!(%{id: HostRuntime, start: {HostRuntime, :start_host_runtime_link, [config]}})
    assert_receive {:executor_started, "task-expiry", _executor}, 1_000
    active = HostRuntime.read_host_runtime_state(runtime).active
    send(runtime, {:local_deadline, active.task_id, active.deadline_generation})

    eventually_host_runtime(fn -> host_terminal_events() |> length() == 1 end)
    assert HostRuntime.read_host_runtime_state(runtime).active.phase == :delivering
    send(runtime, {:retry_terminal, "task-expiry"})
    eventually_host_runtime(fn -> host_terminal_events() |> length() == 2 end)

    [first, second] = host_terminal_events()
    assert first.payload["event_id"] == second.payload["event_id"]
    assert first.payload["summary"]["reason"] == "lease_lost"
    assert first.payload["summary"]["failure_evidence"] == %{"kind" => "local_deadline_expired", "stage" => "lease"}
    assert HostRuntime.read_host_runtime_state(runtime).active == nil
  end

  test "a post-spawn crash is runtime failure and a fenced terminal response releases the assignment", %{config: config} do
    HostRuntimeFixture.put_host_fixture(:claims, [host_runtime_claim("task-crash", "crash")])
    HostRuntimeFixture.put_host_fixture(:terminal_outcomes, [{:error, {:http_error, 409, %{"error" => "lease_conflict"}}}])
    runtime = start_supervised!(%{id: HostRuntime, start: {HostRuntime, :start_host_runtime_link, [config]}})

    assert_receive {:executor_started, "task-crash", _executor}, 1_000
    eventually_host_runtime(fn -> host_terminal_events() |> length() == 1 end)
    assert [event] = host_terminal_events()
    assert event.payload["summary"]["reason"] == "worker_error"
    assert event.payload["summary"]["phase"] == "codex"
    assert HostRuntime.read_host_runtime_state(runtime).active == nil
  end

  defp host_runtime_claim(task_id, mode) do
    %{
      "task_id" => task_id,
      "lease_id" => "lease-#{task_id}",
      "project_id" => "project-1",
      "run_id" => "run-#{task_id}",
      "issue_id" => "issue-#{task_id}",
      "issue_identifier" => "SYM-182",
      "run_attempt" => 0,
      "lease_attempt" => 1,
      "mode" => mode,
      "execution" => %{"required_gates" => []}
    }
  end

  defp host_terminal_events do
    HostRuntimeFixture.host_fixture_state().events
    |> Enum.filter(&(&1.type in ["task.completed", "task.failed", "task.cancelled"]))
  end

  defp eventually_host_runtime(fun, attempts \\ 100)
  defp eventually_host_runtime(fun, 0), do: assert(fun.())

  defp eventually_host_runtime(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually_host_runtime(fun, attempts - 1)
    end
  end
end
