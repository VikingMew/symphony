defmodule SymphonyElixir.WebFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint
  @worker_token "fake-worker-token"

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: @worker_token)
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:worker_api, previous_worker_api)
    end)

    :ok
  end

  test "projects page renders fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/projects")

    assert html =~ "Fake Project"
    assert html =~ "fake"
  end

  test "workflow page saves through fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/workflows")
    assert html =~ "Raw WORKFLOW.md"

    raw = File.read!(Workflow.workflow_file_path())

    html =
      view
      |> form("form", workflow: %{raw: raw})
      |> render_submit()

    assert html =~ "Runtime workflow refreshed"

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, %{id: "fake-project-id"}, ^raw, "web"} -> true
             _ -> false
           end)
  end

  test "worker API uses fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    assert %{"error" => %{"code" => "worker_unauthorized"}} =
             build_conn()
             |> put_req_header("authorization", "Bearer wrong")
             |> post("/api/worker/v1/register", worker_registration_payload())
             |> json_response(401)

    assert %{
             "worker_id" => worker_id,
             "session_id" => session_id,
             "accepted_protocol_version" => "worker-api-v1"
           } =
             build_conn()
             |> put_req_header("authorization", "Bearer #{@worker_token}")
             |> post("/api/worker/v1/register", worker_registration_payload())
             |> json_response(200)

    assert %{"task" => nil} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/claim", %{"available_slots" => 1})
             |> json_response(200)

    assert %{"ok" => true, "lease_renewals" => []} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/heartbeat", %{"active_leases" => []})
             |> json_response(200)

    assert %{"accepted" => true} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/fake-task/events", %{"event_type" => "task.completed", "payload" => %{}})
             |> json_response(202)

    assert Enum.any?(FakePersistence.calls(), fn
             {:register_worker, %{"worker_name" => "fake-worker"}} -> true
             _ -> false
           end)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp worker_registration_payload do
    %{
      "worker_name" => "fake-worker",
      "worker_version" => "0.1.0",
      "protocol_version" => "worker-api-v1",
      "instance_id" => "test-instance"
    }
  end

  defp worker_headers(conn, worker_id, session_id) do
    conn
    |> put_req_header("x-symphony-worker-protocol", "worker-api-v1")
    |> put_req_header("x-symphony-worker-id", worker_id)
    |> put_req_header("x-symphony-worker-session", session_id)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
