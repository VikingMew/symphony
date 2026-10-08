defmodule SymphonyElixir.Worker.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Client

  test "uses the landed worker-v1 protocol identifier" do
    assert Client.protocol_version() == "worker-api-v1"
  end

  test "transient HTTP retry reuses the event UUID from the first request" do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)["payload"]
      send(owner, {:sent_event, payload})
      attempt = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
      status = if attempt == 0, do: 503, else: 202
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, "{}")
    end

    config = %SymphonyElixir.Worker.Config{
      registration_token: "test",
      worker_name: "test",
      workspace_root: "/unused/workspace",
      cache_root: "/unused/cache",
      log_root: "/unused/log",
      panel_url: "http://worker.test",
      request_options: [plug: plug, retry_delay: fn _ -> 0 end]
    }

    assert {:ok, %{}} = Client.event(config, %{}, "task-1", "task.progress", %{phase: "running"})
    assert_receive {:sent_event, payload}
    assert_receive {:sent_event, ^payload}
    assert {:ok, _id} = Ecto.UUID.cast(payload["event_id"])
    assert Agent.get(counter, & &1) == 2
  end
end
