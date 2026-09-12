defmodule SymphonyElixir.WebFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Worker.{AssignmentManager, HeartbeatHistory, HeartbeatMetrics}

  @endpoint SymphonyElixirWeb.Endpoint
  @worker_token "fake-worker-token"

  defmodule EventWithoutCorrelationPersistence do
    @moduledoc false

    defdelegate worker_protocol_version(), to: FakePersistence

    @spec record_worker_task_event(String.t(), String.t(), String.t(), String.t(), map()) ::
            {:ok, map()}
    def record_worker_task_event(_worker_id, _session_id, _task_id, _event_type, _payload) do
      {:ok, %{id: "event-without-correlation", payload: %{}}}
    end
  end

  defmodule EmptyTracker do
    @moduledoc false

    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def update_issue_state(_id, _state), do: :ok
  end

  defmodule EmptyWorkflows do
    @moduledoc false

    def list_enabled, do: []
  end

  defmodule SlowHeartbeatPersistence do
    @moduledoc false

    defdelegate worker_protocol_version(), to: FakePersistence
    defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence
    defdelegate valid_worker_registration_token?(token), to: FakePersistence
    defdelegate register_worker(attrs), to: FakePersistence
    defdelegate active_worker_session(worker_id, session_id), to: FakePersistence
    defdelegate worker_session_identity(worker_id, session_id), to: FakePersistence
    defdelegate fresh_worker_session(worker_id, session_id, opts \\ []), to: FakePersistence
    defdelegate expire_stale_worker_sessions(opts \\ []), to: FakePersistence
    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate current_workflow(project), to: FakePersistence
    defdelegate workflow_to_loaded(record), to: FakePersistence

    @spec heartbeat_worker(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
    def heartbeat_worker(worker_id, session_id) do
      send(Application.fetch_env!(:symphony_elixir, :heartbeat_test_owner), {:slow_heartbeat_started, self()})

      receive do
        :release_heartbeat -> FakePersistence.heartbeat_worker(worker_id, session_id)
      end
    end
  end

  defmodule FailingHeartbeatPersistence do
    @moduledoc false

    defdelegate worker_protocol_version(), to: FakePersistence
    defdelegate worker_heartbeat_interval_seconds(), to: FakePersistence
    defdelegate worker_lease_duration_seconds(), to: FakePersistence
    defdelegate valid_worker_registration_token?(token), to: FakePersistence
    defdelegate register_worker(attrs), to: FakePersistence
    defdelegate active_worker_session(worker_id, session_id), to: FakePersistence
    defdelegate worker_session_identity(worker_id, session_id), to: FakePersistence
    defdelegate fresh_worker_session(worker_id, session_id, opts \\ []), to: FakePersistence
    defdelegate expire_stale_worker_sessions(opts \\ []), to: FakePersistence
    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate current_workflow(project), to: FakePersistence
    defdelegate workflow_to_loaded(record), to: FakePersistence

    @spec heartbeat_worker(String.t(), String.t()) :: {:error, :heartbeat_history_failed}
    def heartbeat_worker(worker_id, session_id) do
      send(
        Application.fetch_env!(:symphony_elixir, :heartbeat_test_owner),
        {:failed_heartbeat_history, worker_id, session_id}
      )

      {:error, :heartbeat_history_failed}
    end
  end

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
                    %{"id" => "state-review", "name" => "Ready to Merge", "type" => "started"},
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
    previous_heartbeat_owner = Application.get_env(:symphony_elixir, :heartbeat_test_owner)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: @worker_token)
    Application.put_env(:symphony_elixir, :linear_diagnostics_client_module, FakeLinearClient)
    System.put_env("LINEAR_API_KEY", "fake-linear-token")
    FakePersistence.reset!()
    HeartbeatMetrics.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:worker_api, previous_worker_api)
      restore_app_env(:linear_diagnostics_client_module, previous_linear_client)
      restore_app_env(:linear_discovery_fake, previous_linear_fake)
      restore_app_env(:heartbeat_test_owner, previous_heartbeat_owner)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    :ok
  end

  test "worker API uses fake persistence without Repo" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
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

    assert %{"task" => nil, "admission" => %{"capacity" => 0, "reason" => "worker_dispatch_disabled"}} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/claim", %{"available_slots" => 1})
             |> json_response(200)

    assert %{"ok" => true, "lease_renewals" => []} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/heartbeat", %{"active_leases" => []})
             |> json_response(200)

    assert %{"error" => %{"code" => "lease_not_active"}} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/fake-task/events", %{"event_type" => "task.completed", "payload" => %{}})
             |> json_response(409)

    assert Enum.any?(FakePersistence.calls(), fn
             {:register_worker, %{"worker_name" => "fake-worker"}} -> true
             _ -> false
           end)
  end

  test "concurrent heartbeat HTTP requests under slow history persistence return 200 without retry advice" do
    Application.put_env(:symphony_elixir, :persistence_module, SlowHeartbeatPersistence)
    Application.put_env(:symphony_elixir, :heartbeat_test_owner, self())
    start_test_endpoint()
    start_assignment_manager(SlowHeartbeatPersistence)
    start_heartbeat_history(coalesce_ms: 20)

    %{"worker_id" => worker_id, "session_id" => session_id} =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@worker_token}")
      |> post("/api/worker/v1/register", worker_registration_payload())
      |> json_response(200)

    expire_worker_liveness(worker_id, session_id)
    assert AssignmentManager.available_worker_slots() == 0

    requests =
      for _ <- 1..3 do
        Task.async(fn ->
          build_conn()
          |> worker_headers(worker_id, session_id)
          |> post("/api/worker/v1/heartbeat", %{"active_leases" => []})
        end)
      end

    conns = Task.await_many(requests, 500)
    statuses = Enum.map(conns, & &1.status)

    assert statuses == [200, 200, 200]
    refute 500 in statuses

    for conn <- conns do
      assert Plug.Conn.get_resp_header(conn, "retry-after") == []
      assert %{"ok" => true, "lease_renewals" => [], "commands" => []} = json_response(conn, 200)
    end

    assert HeartbeatMetrics.snapshot() == %{heartbeat_failed_attempts: 0}
    eventually(fn -> AssignmentManager.available_worker_slots() == 1 end)
    assert_receive {:slow_heartbeat_started, blocked_pid}, 500
    refute_receive {:slow_heartbeat_started, _pid}, 50
    send(blocked_pid, :release_heartbeat)
  end

  test "claim observes expired liveness after admission so the following claim is fresh" do
    start_test_endpoint()
    start_assignment_manager(FakePersistence)

    %{"worker_id" => worker_id, "session_id" => session_id} =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@worker_token}")
      |> post("/api/worker/v1/register", worker_registration_payload())
      |> json_response(200)

    expire_worker_liveness(worker_id, session_id)

    assert %{"task" => nil, "admission" => %{"capacity" => 0, "reason" => "worker_session_stale"}} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/claim", %{"available_slots" => 1})
             |> json_response(200)

    refute old_freshness_predicate_called?()

    assert %{"task" => nil, "admission" => %{"capacity" => 0, "reason" => "no_eligible_candidate"}} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/claim", %{"available_slots" => 1})
             |> json_response(200)
  end

  test "failed heartbeat history writes do not change the heartbeat HTTP response" do
    Application.put_env(:symphony_elixir, :persistence_module, FailingHeartbeatPersistence)
    Application.put_env(:symphony_elixir, :heartbeat_test_owner, self())
    start_test_endpoint()
    start_assignment_manager(FailingHeartbeatPersistence)
    start_heartbeat_history(coalesce_ms: 0)

    %{"worker_id" => worker_id, "session_id" => session_id} =
      build_conn()
      |> put_req_header("authorization", "Bearer #{@worker_token}")
      |> post("/api/worker/v1/register", worker_registration_payload())
      |> json_response(200)

    conn =
      build_conn()
      |> worker_headers(worker_id, session_id)
      |> post("/api/worker/v1/heartbeat", %{"active_leases" => []})

    assert Plug.Conn.get_resp_header(conn, "retry-after") == []
    assert %{"ok" => true, "lease_renewals" => [], "commands" => []} = json_response(conn, 200)
    assert HeartbeatMetrics.snapshot() == %{heartbeat_failed_attempts: 0}
    assert_receive {:failed_heartbeat_history, ^worker_id, ^session_id}, 500
  end

  test "heartbeat history observer coalesces repeated idle observations" do
    start_heartbeat_history(coalesce_ms: 20)
    {:ok, %{worker: worker, session: session}} = FakePersistence.register_worker(worker_registration_payload())

    for _ <- 1..3 do
      HeartbeatHistory.observe(worker.id, session.id, FakePersistence)
    end

    eventually(fn -> heartbeat_worker_calls(worker.id, session.id) == 1 end)
    Process.sleep(30)
    assert heartbeat_worker_calls(worker.id, session.id) == 1
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

    assert %{"error" => %{"code" => "worker_session_not_found"}} =
             build_conn()
             |> post("/api/worker/v1/heartbeat", %{})
             |> json_response(401)

    assert %{"error" => %{"code" => "unsupported_worker_protocol"}} =
             build_conn()
             |> put_req_header("x-symphony-worker-protocol", "worker-api-v0")
             |> post("/api/worker/v1/heartbeat", %{"worker_id" => "worker", "session_id" => "session"})
             |> json_response(426)

    assert %{"error" => %{"code" => "invalid_worker_event"}} =
             build_conn()
             |> put_req_header("x-symphony-worker-protocol", "worker-api-v1")
             |> put_req_header("x-symphony-worker-id", "worker")
             |> put_req_header("x-symphony-worker-session", "session")
             |> post("/api/worker/v1/tasks/task-1/events", %{})
             |> json_response(422)

    assert HeartbeatMetrics.snapshot() == %{heartbeat_failed_attempts: 0}
  end

  test "terminal worker event without a current assignment is rejected" do
    Application.put_env(
      :symphony_elixir,
      :persistence_module,
      EventWithoutCorrelationPersistence
    )

    start_test_endpoint()

    assert %{"error" => %{"code" => "lease_not_active"}} =
             build_conn()
             |> worker_headers("worker", "session")
             |> post("/api/worker/v1/tasks/task-1/events", %{
               "event_type" => "task.completed",
               "payload" => %{}
             })
             |> json_response(409)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp start_assignment_manager(persistence) do
    start_supervised!({AssignmentManager, name: AssignmentManager, tracker: EmptyTracker, persistence: persistence, workflows: EmptyWorkflows, reconcile_interval_ms: :timer.hours(1)})
  end

  defp start_heartbeat_history(opts) do
    start_supervised!({HeartbeatHistory, opts})
  end

  defp worker_registration_payload do
    %{
      "worker_name" => "fake-worker",
      "worker_version" => "0.1.0",
      "protocol_version" => "worker-api-v1",
      "total_slots" => 1,
      "instance_id" => "test-instance"
    }
  end

  defp worker_headers(conn, worker_id, session_id) do
    conn
    |> put_req_header("x-symphony-worker-protocol", "worker-api-v1")
    |> put_req_header("x-symphony-worker-id", worker_id)
    |> put_req_header("x-symphony-worker-session", session_id)
  end

  defp heartbeat_worker_calls(worker_id, session_id) do
    Enum.count(FakePersistence.calls(), fn
      {:heartbeat_worker, ^worker_id, ^session_id} -> true
      _other -> false
    end)
  end

  defp expire_worker_liveness(worker_id, session_id) do
    key = {worker_id, session_id}

    :sys.replace_state(AssignmentManager, fn state ->
      update_in(state.liveness[key].last_seen_at, fn _last_seen_at ->
        DateTime.add(DateTime.utc_now(), -31, :second)
      end)
    end)
  end

  defp old_freshness_predicate_called? do
    Enum.any?(FakePersistence.calls(), fn
      {:fresh_worker_session, _worker_id, _session_id, _opts} -> true
      _call -> false
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

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
