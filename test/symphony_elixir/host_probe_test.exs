defmodule SymphonyElixir.HostProbeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config.Schema, ExecutionRequirement}
  alias SymphonyElixir.HostProbe.{PreparedWorkspace, Token}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Worker.{Client, Config}

  test "normalizes host-only and capability labels and enforces the routing matrix" do
    assert ExecutionRequirement.from_labels([" execution:HOST-only ", "capability:gui-session", "capability:manual-pr-handoff"]) == %{
             execution_requirement: "host_only",
             required_capabilities: ["gui-session", "manual-pr-handoff"]
           }

    unmarked = host_probe_issue([])
    host_only = host_probe_issue(["execution:host-only"])
    gui = host_probe_issue(["execution:host-only", "capability:gui-session"])
    container = session("container_worker", [])
    host = session("host_probe", [])

    assert :ok = ExecutionRequirement.admit(unmarked, container)
    assert {:skip, :host_only_surface_required} = ExecutionRequirement.admit(host_only, container)
    assert {:skip, :host_probe_requires_host_only} = ExecutionRequirement.admit(unmarked, host)
    assert :ok = ExecutionRequirement.admit(host_only, host)
    assert {:skip, :required_capabilities_unavailable} = ExecutionRequirement.admit(gui, host)
    assert :ok = ExecutionRequirement.admit(gui, session("host_probe", ["gui-session"]))
  end

  test "freezes one stable allowlisted capability digest and fixed installation policy" do
    assert {:ok, capabilities} =
             ExecutionRequirement.normalize_capabilities(%{
               "values" => ["manual-pr-handoff", "gui-session", "gui-session"]
             })

    assert capabilities == ["gui-session", "manual-pr-handoff"]

    assert ExecutionRequirement.capability_digest(capabilities) ==
             ExecutionRequirement.capability_digest(Enum.reverse(capabilities))

    assert {:error, :invalid_host_probe_capabilities} =
             ExecutionRequirement.normalize_capabilities(["shell"])

    assert {:ok, settings} = Schema.parse(%{})

    assert %{
             enabled: false,
             heartbeat_interval_seconds: 5,
             lease_duration_seconds: 30,
             local_deadline_seconds: 30
           } = settings.host_probe

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "host_probe" => %{
                 "enabled" => true,
                 "auth_token" => "secret",
                 "heartbeat_interval_seconds" => 10
               }
             })

    assert message =~ "heartbeat_interval_seconds"
  end

  test "token loader requires a non-empty owner-only regular file" do
    path = Path.join(tmp_dir("token"), "probe-token")
    assert {:error, :missing_token_file} = Token.load_bearer(path)
    File.write!(path, "probe-secret\n")
    File.chmod!(path, 0o644)
    assert {:error, :invalid_token_file_mode} = Token.load_bearer(path)
    File.chmod!(path, 0o600)
    assert {:ok, "probe-secret"} = Token.load_bearer(path)
  end

  test "prepared workspace accepts only the writable issue directory below its root" do
    root = tmp_dir("workspace")
    workspace = Path.join(root, "sym-175")
    File.mkdir_p!(workspace)
    assert {:ok, Path.expand(workspace)} == PreparedWorkspace.locate(root, "SYM-175")

    assert {:error, :workspace_unavailable, %{reason: "missing", workspace_key: "sym-176"}} =
             PreparedWorkspace.locate(root, "SYM-176")

    File.chmod!(workspace, 0o500)

    assert {:error, :workspace_unavailable, %{reason: "unwritable", workspace_key: "sym-175"}} =
             PreparedWorkspace.locate(root, "SYM-175")
  end

  test "worker client authenticates endpoints, redacts its token, and types transport failure" do
    owner = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "{}")
    end

    config = host_probe_config(plug)
    identity = %{"worker_id" => "worker", "session_id" => "session"}
    assert {:ok, %{}} = Client.register(config)
    assert {:ok, %{}} = Client.claim(config, identity)
    assert {:ok, %{}} = Client.heartbeat(config, identity, %{})
    assert {:ok, %{}} = Client.event(config, identity, "task", "task.progress", %{})

    for path <- ["/api/worker/v1/register", "/api/worker/v1/tasks/claim", "/api/worker/v1/heartbeat", "/api/worker/v1/tasks/task/events"] do
      assert_receive {^path, ["Bearer probe-secret"], body}
      refute inspect(body) =~ "probe-secret"
    end

    unreachable = %{host_probe_config(nil) | panel_url: "http://127.0.0.1:1", request_options: [retry: false]}
    assert {:error, {:transport_error, _reason}} = Client.claim(unreachable, %{})
  end

  defp host_probe_issue(labels),
    do: %Issue{id: "issue", identifier: "SYM-175", title: "Host probe", state: "Ready", blocked_by: [], labels: labels}

  defp session(surface, capabilities),
    do: %{execution_surface: surface, capabilities: %{"values" => capabilities}}

  defp host_probe_config(plug) do
    %Config{
      registration_token: "probe-secret",
      worker_name: "local-host",
      workspace_root: "/unused/workspace",
      cache_root: "/unused/cache",
      log_root: "/unused/log",
      panel_url: "http://127.0.0.1:4001",
      execution_surface: "host_probe",
      probe_id: "local-host",
      capabilities: ["gui-session"],
      request_options: if(plug, do: [plug: plug], else: [])
    }
  end

  defp tmp_dir(suffix) do
    path = Path.join(File.cwd!(), ".host-probe-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
