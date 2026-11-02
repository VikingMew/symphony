defmodule SymphonyElixir.HostProbeAuthTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, TestSupport.FakePersistence}
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixirWeb.WorkerApiController

  @workflow %{setup_required: false, config: %{"host_probe" => %{"enabled" => true, "auth_token" => "panel-secret"}}}

  setup do
    previous = Application.get_env(:symphony_elixir, :persistence_module)
    FakePersistence.reset!()
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :persistence_module, previous),
        else: Application.delete_env(:symphony_elixir, :persistence_module)
    end)
  end

  test "missing and wrong bearer tokens reject all host-probe endpoints before side effects" do
    Config.with_workflow_context(@workflow, fn ->
      for token <- [nil, "wrong-secret"], endpoint <- [:register, :claim, :heartbeat, :event] do
        response = probe_request(endpoint, token)
        body = Jason.decode!(response.resp_body)
        assert response.status == 401
        assert body["error"]["code"] == "host_probe_unauthorized"
        refute response.resp_body =~ "panel-secret"
        refute response.resp_body =~ "wrong-secret"
      end
    end)

    assert FakePersistence.calls() == []
  end

  test "a frozen host session cannot omit its execution surface to bypass bearer authentication" do
    if is_nil(Process.whereis(AssignmentManager)) do
      start_supervised!({AssignmentManager, name: AssignmentManager, persistence: FakePersistence, reconcile_interval_ms: :timer.hours(1)})
    end

    :ok =
      AssignmentManager.observe_session(
        %{id: "worker-omission"},
        %{id: "session-omission", total_slots: 1, execution_surface: "host_probe", probe_id: "local-host", capability_digest: "digest"}
      )

    params =
      probe_identity()
      |> Map.put("worker_id", "worker-omission")
      |> Map.put("session_id", "session-omission")
      |> Map.delete("execution_surface")

    Config.with_workflow_context(@workflow, fn ->
      assert probe_request(:claim, nil, params).status == 401
      response = probe_request(:claim, "panel-secret", params)
      assert response.status == 401
      assert Jason.decode!(response.resp_body)["error"]["code"] == "host_probe_identity_mismatch"
    end)
  end

  defp probe_request(endpoint, token, params \\ nil) do
    conn = Plug.Test.conn(:post, "/#{endpoint}")
    conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    dispatch_probe_endpoint(endpoint, conn, params)
  end

  defp dispatch_probe_endpoint(:register, conn, _params), do: WorkerApiController.register(conn, probe_registration())
  defp dispatch_probe_endpoint(:claim, conn, params), do: WorkerApiController.claim(conn, params || probe_identity())
  defp dispatch_probe_endpoint(:heartbeat, conn, _params), do: WorkerApiController.heartbeat(conn, probe_identity())

  defp dispatch_probe_endpoint(:event, conn, _params) do
    params = Map.merge(probe_identity(), %{"task_id" => "task", "event_type" => "task.progress", "payload" => %{}})
    WorkerApiController.task_event(conn, params)
  end

  defp probe_registration do
    %{"execution_surface" => "host_probe", "probe_id" => "local-host", "worker_name" => "local-host", "protocol_version" => "worker-api-v1", "total_slots" => 1, "capabilities" => %{"values" => []}}
  end

  defp probe_identity do
    %{"worker_id" => "worker", "session_id" => "session", "protocol_version" => "worker-api-v1", "execution_surface" => "host_probe", "probe_id" => "local-host", "capability_digest" => "digest"}
  end
end
