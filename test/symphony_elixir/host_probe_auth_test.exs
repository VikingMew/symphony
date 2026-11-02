defmodule SymphonyElixir.HostProbeAuthTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixirWeb.WorkerApiController

  setup do
    previous = Application.get_env(:symphony_elixir, :persistence_module)
    FakePersistence.reset!()
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:symphony_elixir, :persistence_module),
        else: Application.put_env(:symphony_elixir, :persistence_module, previous)
    end)
  end

  test "missing and wrong bearer tokens reject all host-probe endpoints before side effects" do
    workflow = %{
      setup_required: false,
      config: %{"host_probe" => %{"enabled" => true, "auth_token" => "panel-secret"}}
    }

    Config.with_workflow_context(workflow, fn ->
      Enum.each([nil, "wrong-secret"], fn token ->
        assert probe_unauthorized(probe_conn(:post, "/register", token), fn request ->
                 WorkerApiController.register(request, probe_registration_payload())
               end)

        assert probe_unauthorized(probe_conn(:post, "/claim", token), fn request ->
                 WorkerApiController.claim(request, probe_identity_payload())
               end)

        assert probe_unauthorized(probe_conn(:post, "/heartbeat", token), fn request ->
                 WorkerApiController.heartbeat(request, probe_identity_payload())
               end)

        assert probe_unauthorized(probe_conn(:post, "/events", token), fn request ->
                 WorkerApiController.task_event(
                   request,
                   Map.merge(probe_identity_payload(), %{
                     "task_id" => "task",
                     "event_type" => "task.progress",
                     "payload" => %{}
                   })
                 )
               end)
      end)
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
        %{
          id: "session-omission",
          total_slots: 1,
          execution_surface: "host_probe",
          probe_id: "local-host",
          capability_digest: "digest"
        }
      )

    workflow = %{setup_required: false, config: %{"host_probe" => %{"enabled" => true, "auth_token" => "panel-secret"}}}

    Config.with_workflow_context(workflow, fn ->
      params = probe_identity_payload() |> Map.put("worker_id", "worker-omission") |> Map.put("session_id", "session-omission")
      omitted = Map.delete(params, "execution_surface")

      assert probe_unauthorized(probe_conn(:post, "/claim", nil), fn request ->
               WorkerApiController.claim(request, omitted)
             end)

      response = WorkerApiController.claim(probe_conn(:post, "/claim", "panel-secret"), omitted)
      assert response.status == 401
      assert Jason.decode!(response.resp_body)["error"]["code"] == "host_probe_identity_mismatch"
    end)
  end

  defp probe_unauthorized(request, call) do
    response = call.(request)
    body = Jason.decode!(response.resp_body)

    response.status == 401 and body["error"]["code"] == "host_probe_unauthorized" and
      String.contains?(response.resp_body, "panel-secret") == false and
      String.contains?(response.resp_body, "wrong-secret") == false
  end

  defp probe_conn(method, path, nil), do: Plug.Test.conn(method, path)

  defp probe_conn(method, path, token) do
    method
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
  end

  defp probe_registration_payload do
    %{
      "execution_surface" => "host_probe",
      "probe_id" => "local-host",
      "worker_name" => "local-host",
      "protocol_version" => "worker-api-v1",
      "total_slots" => 1,
      "capabilities" => %{"values" => []}
    }
  end

  defp probe_identity_payload do
    %{
      "worker_id" => "worker",
      "session_id" => "session",
      "protocol_version" => "worker-api-v1",
      "execution_surface" => "host_probe",
      "probe_id" => "local-host",
      "capability_digest" => "digest"
    }
  end
end
