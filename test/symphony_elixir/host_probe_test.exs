defmodule SymphonyElixir.HostProbeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.HostProbe.{PreparedWorkspace, Token}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Worker.{Client, Config}

  test "normalizes the exact host-only requirement and capability label set" do
    evidence =
      ExecutionRequirement.from_labels([
        " execution:HOST-only ",
        "capability:gui-session",
        "capability:manual-pr-handoff"
      ])

    assert evidence == %{
             execution_requirement: "host_only",
             required_capabilities: ["gui-session", "manual-pr-handoff"]
           }
  end

  test "admits only the routing matrix selected by the frozen session" do
    unmarked = host_issue([])
    host_only = host_issue(["execution:host-only"])
    gui = host_issue(["execution:host-only", "capability:gui-session"])

    container = %{execution_surface: "container_worker", capabilities: %{"values" => []}}
    host = %{execution_surface: "host_probe", capabilities: %{"values" => []}}
    gui_host = %{execution_surface: "host_probe", capabilities: %{"values" => ["gui-session"]}}

    assert :ok = ExecutionRequirement.admit(unmarked, container)
    assert {:skip, :host_only_surface_required} = ExecutionRequirement.admit(host_only, container)
    assert {:skip, :host_probe_requires_host_only} = ExecutionRequirement.admit(unmarked, host)
    assert :ok = ExecutionRequirement.admit(host_only, host)
    assert {:skip, :required_capabilities_unavailable} = ExecutionRequirement.admit(gui, host)
    assert :ok = ExecutionRequirement.admit(gui, gui_host)
  end

  test "freezes a stable digest over the allowlisted capability set" do
    assert {:ok, capabilities} =
             ExecutionRequirement.normalize_capabilities(%{
               "values" => ["manual-pr-handoff", "gui-session", "gui-session"]
             })

    assert capabilities == ["gui-session", "manual-pr-handoff"]

    assert ExecutionRequirement.capability_digest(capabilities) ==
             ExecutionRequirement.capability_digest(Enum.reverse(capabilities))

    assert {:error, :invalid_host_probe_capabilities} =
             ExecutionRequirement.normalize_capabilities(["shell"])
  end

  test "host-probe installation policy is disabled and fixed to 5/30/30 by default" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.host_probe.enabled == false
    assert settings.host_probe.heartbeat_interval_seconds == 5
    assert settings.host_probe.lease_duration_seconds == 30
    assert settings.host_probe.local_deadline_seconds == 30

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

  test "token loading rejects missing and non-0600 files before returning the secret" do
    root = tmp_dir("token")
    path = Path.join(root, "probe-token")

    assert {:error, :missing_token_file} = Token.load_bearer(path)
    File.write!(path, "probe-secret\n")
    File.chmod!(path, 0o644)
    assert {:error, :invalid_token_file_mode} = Token.load_bearer(path)
    File.chmod!(path, 0o600)
    assert {:ok, "probe-secret"} = Token.load_bearer(path)
  end

  test "prepared workspace resolution accepts only the writable issue directory below the root" do
    root = tmp_dir("workspace")
    workspace = Path.join(root, "sym-175")
    File.mkdir_p!(workspace)

    assert {:ok, resolved} = PreparedWorkspace.locate(root, "SYM-175")
    assert resolved == Path.expand(workspace)

    assert {:error, :workspace_unavailable, %{reason: "missing", workspace_key: "sym-176"}} =
             PreparedWorkspace.locate(root, "SYM-176")

    File.chmod!(workspace, 0o500)

    assert {:error, :workspace_unavailable, %{reason: "unwritable", workspace_key: "sym-175"}} =
             PreparedWorkspace.locate(root, "SYM-175")
  end

  test "worker client authenticates registration claim heartbeat and events with one bearer token" do
    owner = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "{}")
    end

    config = host_probe_config(plug)
    identity = %{"worker_id" => "worker", "session_id" => "session"}

    assert {:ok, %{}} = Client.register(config)
    assert {:ok, %{}} = Client.claim(config, identity)
    assert {:ok, %{}} = Client.heartbeat(config, identity, %{})
    assert {:ok, %{}} = Client.event(config, identity, "task", "task.progress", %{})

    assert_receive {:request, "/api/worker/v1/register", ["Bearer probe-secret"], register_body}
    assert_receive {:request, "/api/worker/v1/tasks/claim", ["Bearer probe-secret"], ^identity}
    assert_receive {:request, "/api/worker/v1/heartbeat", ["Bearer probe-secret"], ^identity}
    assert_receive {:request, "/api/worker/v1/tasks/task/events", ["Bearer probe-secret"], event_body}
    assert event_body["worker_id"] == "worker"
    assert event_body["payload"]["event_id"] != nil
    assert String.contains?(inspect([register_body, identity, event_body]), "probe-secret") == false
  end

  test "root-unreachable requests return the typed transport error" do
    config = %{host_probe_config(nil) | panel_url: "http://127.0.0.1:1", request_options: [retry: false]}

    assert {:error, {:transport_error, _reason}} = Client.claim(config, %{})
  end

  defp host_issue(labels) do
    %Issue{
      id: "issue",
      identifier: "SYM-175",
      title: "Host probe",
      state: "Ready",
      blocked_by: [],
      labels: labels
    }
  end

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
      request_options: if(is_nil(plug), do: [], else: [plug: plug])
    }
  end

  defp tmp_dir(suffix) do
    path = Path.join(File.cwd!(), ".host-probe-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
