defmodule SymphonyElixirWeb.ControlApiControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Auth

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}

    def handle_call(request, _from, owner) do
      send(owner, {:orchestrator_call, request})
      {:reply, response(request), owner}
    end

    defp response(:start_listening), do: %{listening: true, mode: "all"}
    defp response(:start_refine_only_listening), do: %{listening: true, mode: "refine_only"}
    defp response(:stop_listening), do: %{listening: false, mode: "off"}
    defp response(:reset_environment_failure_circuit), do: %{environment_failure_circuit: %{active: false, status: "allow"}}
    defp response(:force_stop_all), do: force_stop_response(cancelled_tasks("cancelled", nil))

    defp response({:cancel_current_task, "none"}),
      do: cancel_response(cancelled_tasks("no_active_assignment", "none"))

    defp response({:cancel_current_task, "failed"}),
      do: cancel_response(cancelled_tasks("failed", "failed"))

    defp response({:cancel_current_task, project_id}),
      do: cancel_response(cancelled_tasks("cancelled", project_id))

    defp response({:request_operator_task, kind, project_id}),
      do: %{status: "failed", kind: Atom.to_string(kind), project_id: project_id}

    defp force_stop_response(cancelled_tasks) do
      %{
        listening?: false,
        listening_mode: "not_listening",
        stopped_agents: 0,
        cancelled_tasks: cancelled_tasks,
        rollback_results: [],
        changed_at: DateTime.utc_now()
      }
    end

    defp cancel_response(cancelled_tasks) do
      %{
        listening?: true,
        listening_mode: "listening_all",
        cancelled_tasks: cancelled_tasks,
        changed_at: DateTime.utc_now()
      }
    end

    defp cancelled_tasks("cancelled", project_id) do
      %{
        status: "cancelled",
        cancelled: 1,
        failed: [],
        project_id: project_id,
        tasks: [%{assignment_id: "assignment-1", task_id: "assignment-1", project_id: project_id}]
      }
    end

    defp cancelled_tasks("no_active_assignment", project_id) do
      %{status: "no_active_assignment", cancelled: 0, failed: [], project_id: project_id, tasks: []}
    end

    defp cancelled_tasks("failed", project_id) do
      %{
        status: "failed",
        cancelled: 0,
        failed: [%{assignment_id: "assignment-1", reason: "worker_termination_timeout"}],
        project_id: project_id,
        tasks: []
      }
    end
  end

  setup do
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    orchestrator = Module.concat(__MODULE__, :Orchestrator)
    pid = start_supervised!({FakeOrchestrator, name: orchestrator, owner: self()})

    endpoint_config =
      Keyword.merge(previous_endpoint,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: orchestrator
      )

    Application.put_env(:symphony_elixir, :auth, enabled: false)
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      restore_app_env(:auth, previous_auth)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    %{orchestrator: orchestrator, orchestrator_pid: pid}
  end

  test "listening modes call the injected orchestrator and return its map" do
    assert %{"listening" => true, "mode" => "all"} = post_json("/api/v1/control/listening", %{mode: "all"}, 200)
    assert_receive {:orchestrator_call, :start_listening}

    assert %{"listening" => true, "mode" => "refine_only"} =
             post_json("/api/v1/control/listening", %{mode: "refine_only"}, 200)

    assert_receive {:orchestrator_call, :start_refine_only_listening}

    assert %{"listening" => false, "mode" => "off"} = post_json("/api/v1/control/listening", %{mode: "off"}, 200)
    assert_receive {:orchestrator_call, :stop_listening}
  end

  test "environment failure circuit reset calls the injected orchestrator and returns its map" do
    assert %{"environment_failure_circuit" => %{"active" => false, "status" => "allow"}} =
             post_json("/api/v1/control/environment-failure-circuit/reset", %{}, 200)

    assert_receive {:orchestrator_call, :reset_environment_failure_circuit}
  end

  test "force stop calls the injected orchestrator and returns the stop payload" do
    assert %{
             "listening?" => false,
             "listening_mode" => "not_listening",
             "stopped_agents" => 0,
             "rollback_results" => [],
             "cancelled_tasks" => %{"status" => "cancelled", "cancelled" => 1}
           } = post_json("/api/v1/control/force-stop", %{}, 200)

    assert_receive {:orchestrator_call, :force_stop_all}
  end

  test "cancel task forwards optional project ids and preserves listening mode" do
    assert %{
             "listening?" => true,
             "listening_mode" => "listening_all",
             "cancelled_tasks" => %{
               "status" => "cancelled",
               "cancelled" => 1,
               "tasks" => [%{"assignment_id" => "assignment-1"}]
             }
           } = post_json("/api/v1/control/tasks/cancel", %{}, 200)

    assert_receive {:orchestrator_call, {:cancel_current_task, nil}}

    assert %{
             "cancelled_tasks" => %{
               "status" => "cancelled",
               "project_id" => "project-1"
             }
           } = post_json("/api/v1/control/tasks/cancel", %{project_id: "project-1"}, 200)

    assert_receive {:orchestrator_call, {:cancel_current_task, "project-1"}}
  end

  test "cancel task returns distinct typed no-active and failed results" do
    assert %{
             "cancelled_tasks" => %{
               "status" => "no_active_assignment",
               "cancelled" => 0,
               "failed" => [],
               "tasks" => []
             }
           } = post_json("/api/v1/control/tasks/cancel", %{project_id: "none"}, 200)

    assert_receive {:orchestrator_call, {:cancel_current_task, "none"}}

    assert %{
             "cancelled_tasks" => %{
               "status" => "failed",
               "cancelled" => 0,
               "failed" => [%{"reason" => "worker_termination_timeout"}],
               "tasks" => []
             }
           } = post_json("/api/v1/control/tasks/cancel", %{project_id: "failed"}, 200)

    assert_receive {:orchestrator_call, {:cancel_current_task, "failed"}}
  end

  test "listening rejects missing and unknown modes without calling the orchestrator" do
    assert_invalid_parameter("/api/v1/control/listening", %{})
    assert_invalid_parameter("/api/v1/control/listening", %{mode: "sometimes"})
    refute_receive {:orchestrator_call, _request}
  end

  test "nap and daydream forward optional project ids and preserve business results" do
    assert %{"status" => "failed", "kind" => "nap", "project_id" => nil} =
             post_json("/api/v1/control/nap", %{}, 200)

    assert_receive {:orchestrator_call, {:request_operator_task, :nap, nil}}

    assert %{"status" => "failed", "kind" => "nap", "project_id" => "project-1"} =
             post_json("/api/v1/control/nap", %{project_id: "project-1"}, 200)

    assert_receive {:orchestrator_call, {:request_operator_task, :nap, "project-1"}}

    assert %{"status" => "failed", "kind" => "day_dreaming", "project_id" => nil} =
             post_json("/api/v1/control/daydream", %{}, 200)

    assert_receive {:orchestrator_call, {:request_operator_task, :day_dreaming, nil}}

    assert %{"status" => "failed", "kind" => "day_dreaming", "project_id" => " project-2 "} =
             post_json("/api/v1/control/daydream", %{project_id: " project-2 "}, 200)

    assert_receive {:orchestrator_call, {:request_operator_task, :day_dreaming, " project-2 "}}
  end

  test "project-scoped control routes reject present invalid project ids" do
    for path <- ["/api/v1/control/nap", "/api/v1/control/daydream", "/api/v1/control/tasks/cancel"],
        project_id <- ["", "  ", 123, nil] do
      assert_invalid_parameter(path, %{project_id: project_id})
    end

    refute_receive {:orchestrator_call, _request}
  end

  test "control routes map an unavailable orchestrator to 503" do
    endpoint_config = Application.fetch_env!(:symphony_elixir, SymphonyElixirWeb.Endpoint)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :orchestrator, Module.concat(__MODULE__, :MissingOrchestrator))
    )

    for {path, body} <- [
          {"/api/v1/control/listening", %{mode: "all"}},
          {"/api/v1/control/environment-failure-circuit/reset", %{}},
          {"/api/v1/control/force-stop", %{}},
          {"/api/v1/control/tasks/cancel", %{}},
          {"/api/v1/control/nap", %{}},
          {"/api/v1/control/daydream", %{project_id: "project-1"}}
        ] do
      assert %{"error" => %{"code" => "orchestrator_unavailable"}} = post_json(path, body, 503)
    end
  end

  test "defined control paths reject unsupported methods and unknown paths remain 404" do
    for path <- [
          "/api/v1/control/listening",
          "/api/v1/control/environment-failure-circuit/reset",
          "/api/v1/control/force-stop",
          "/api/v1/control/tasks/cancel",
          "/api/v1/control/nap",
          "/api/v1/control/daydream"
        ] do
      assert %{"error" => %{"code" => "method_not_allowed"}} =
               build_conn() |> get(path) |> json_response(405)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             build_conn() |> post("/api/v1/control/unknown", %{}) |> json_response(404)
  end

  test "auth-enabled control routes require and accept the dashboard session" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: Auth.hash_password("secret")
    )

    for path <- [
          "/api/v1/control/listening",
          "/api/v1/control/environment-failure-circuit/reset",
          "/api/v1/control/force-stop",
          "/api/v1/control/tasks/cancel",
          "/api/v1/control/nap",
          "/api/v1/control/daydream"
        ] do
      assert %{"error" => %{"code" => "authentication_required"}} =
               build_conn() |> post(path, %{}) |> json_response(401)
    end

    conn =
      build_conn()
      |> init_test_session(%{symphony_user: "admin"})
      |> post("/api/v1/control/listening", %{mode: "all"})

    assert %{"mode" => "all"} = json_response(conn, 200)
    assert_receive {:orchestrator_call, :start_listening}
  end

  defp post_json(path, body, status), do: build_conn() |> post(path, body) |> json_response(status)

  defp assert_invalid_parameter(path, body) do
    assert %{"error" => %{"code" => "invalid_parameter"}} = post_json(path, body, 400)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
