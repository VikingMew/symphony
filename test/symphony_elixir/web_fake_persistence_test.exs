defmodule SymphonyElixir.WebFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint
  @worker_token "fake-worker-token"

  defmodule FakeLinearClient do
    @moduledoc false

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def graphql(_query, variables, opts) do
      fake = Application.get_env(:symphony_elixir, :linear_discovery_fake, %{})

      case Map.get(fake, Keyword.get(opts, :operation_name)) do
        nil -> {:ok, default_response(Keyword.get(opts, :operation_name), variables)}
        {:error, reason} -> {:error, reason}
        response -> {:ok, response}
      end
    end

    defp default_response("SymphonyLinearDiscoveryViewer", _variables) do
      %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Ops User", "email" => "ops@example.test"}}}
    end

    defp default_response("SymphonyLinearDiscoveryTeams", _variables) do
      %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "id" => "team-1",
                "key" => "PLAT",
                "name" => "Platform"
              }
            ]
          }
        }
      }
    end

    defp default_response("SymphonyLinearDiscoveryTeamStates", %{"teamKey" => "PLAT"}) do
      %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "id" => "team-1",
                "key" => "PLAT",
                "states" => %{
                  "nodes" => [
                    %{"id" => "state-ready", "name" => "Ready", "type" => "unstarted"},
                    %{"id" => "state-progress", "name" => "In Progress", "type" => "started"},
                    %{"id" => "state-review", "name" => "In Review", "type" => "started"},
                    %{"id" => "state-done", "name" => "Done", "type" => "completed"}
                  ]
                }
              }
            ]
          }
        }
      }
    end

    defp default_response("SymphonyLinearDiscoveryTeamStates", _variables) do
      %{"data" => %{"teams" => %{"nodes" => []}}}
    end

    defp default_response("SymphonyLinearDiscoveryProjects", _variables) do
      %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-1",
                "name" => "Migration Project",
                "slugId" => "migration-project",
                "url" => "https://linear.app/project/migration-project",
                "teams" => %{
                  "nodes" => [
                    %{
                      "id" => "team-1",
                      "key" => "PLAT",
                      "name" => "Platform"
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    end

    defp default_response(_operation, _variables), do: %{}
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)
    previous_linear_client = Application.get_env(:symphony_elixir, :linear_diagnostics_client_module)
    previous_linear_fake = Application.get_env(:symphony_elixir, :linear_discovery_fake)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: @worker_token)
    Application.put_env(:symphony_elixir, :linear_diagnostics_client_module, FakeLinearClient)
    System.put_env("LINEAR_API_KEY", "fake-linear-token")
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:worker_api, previous_worker_api)
      restore_app_env(:linear_diagnostics_client_module, previous_linear_client)
      restore_app_env(:linear_discovery_fake, previous_linear_fake)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    :ok
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

  test "worker API returns controller-level errors before persistence work" do
    start_test_endpoint()

    assert %{"error" => %{"code" => "worker_session_not_found"}} =
             build_conn()
             |> post("/api/worker/v1/tasks/claim", %{})
             |> json_response(401)

    assert %{"error" => %{"code" => "unsupported_worker_protocol"}} =
             build_conn()
             |> put_req_header("x-symphony-worker-protocol", "worker-api-v0")
             |> post("/api/worker/v1/tasks/claim", %{"worker_id" => "worker", "session_id" => "session"})
             |> json_response(426)

    assert %{"error" => %{"code" => "invalid_worker_event"}} =
             build_conn()
             |> put_req_header("x-symphony-worker-protocol", "worker-api-v1")
             |> put_req_header("x-symphony-worker-id", "worker")
             |> put_req_header("x-symphony-worker-session", "session")
             |> post("/api/worker/v1/tasks/task-1/events", %{})
             |> json_response(422)
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
