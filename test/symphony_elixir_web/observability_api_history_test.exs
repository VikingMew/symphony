defmodule SymphonyElixirWeb.ObservabilityApiHistoryTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, Keyword.fetch!(opts, :snapshot)}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call(:request_refresh, _from, snapshot), do: {:reply, :unavailable, snapshot}
  end

  defmodule RepoUnavailablePersistence do
    def get_issue_by_identifier(_identifier), do: {:error, :repo_unavailable}
    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate active_workflow_version(project), to: FakePersistence
    defdelegate workflow_to_loaded(version), to: FakePersistence
  end

  defmodule QueryFailurePersistence do
    def get_issue_by_identifier(_identifier), do: raise("history query failed")
    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate active_workflow_version(project), to: FakePersistence
    defdelegate workflow_to_loaded(version), to: FakePersistence
  end

  defmodule BlockingPersistence do
    def get_issue_by_identifier(_identifier) do
      owner = Application.fetch_env!(:symphony_elixir, :history_test_owner)
      send(owner, {:history_read_blocked, self()})

      receive do
        :release -> nil
      end
    end

    def list_runs_for_issue(_identifier, _opts), do: []
    def list_events(_opts), do: []
    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate active_workflow_version(project), to: FakePersistence
    defdelegate workflow_to_loaded(version), to: FakePersistence
  end

  setup do
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_owner = Application.get_env(:symphony_elixir, :history_test_owner)
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: empty_snapshot()})
    start_test_endpoint(orchestrator_name)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:persistence_module, previous_persistence)
      restore_app_env(:history_test_owner, previous_owner)
    end)

    :ok
  end

  test "inactive persisted issue returns identity, latest outcome, bounded runs, and compact timeline" do
    now = DateTime.utc_now()

    FakePersistence.put_issues([
      %{
        id: "issue-db",
        tracker_issue_id: "linear-db",
        identifier: "SYM-3",
        title: "Memory snapshot",
        state: "Ready to Merge",
        url: "https://linear.app/issue/SYM-3",
        project_id: "project-db",
        updated_at: now,
        __meta__: %{internal: true}
      }
    ])

    FakePersistence.put_runs([
      run("run-old", "failed", 1, DateTime.add(now, -120, :second), "old failure"),
      run("run-new", "completed", 2, DateTime.add(now, -60, :second), nil)
    ])

    FakePersistence.put_events([
      event("event-old", "run.failed", DateTime.add(now, -110, :second), %{"reason" => "old failure"}),
      event("event-new", "run.completed", DateTime.add(now, -30, :second), %{"message" => "validation passed"})
    ])

    issue_payload = json_response(get(build_conn(), "/api/v1/SYM-3"), 200)
    assert issue_payload["status"] == "Ready to Merge"
    assert issue_payload["persisted_issue"]["identifier"] == "SYM-3"
    refute Map.has_key?(issue_payload["persisted_issue"], "__meta__")
    assert issue_payload["latest_run"]["id"] == "run-new"
    assert Enum.map(issue_payload["recent_runs"], & &1["id"]) == ["run-new", "run-old"]
    assert hd(issue_payload["timeline"])["event_type"] == "run.completed"

    runs_payload = json_response(get(build_conn(), "/api/v1/runs?issue_identifier=SYM-3&limit=1"), 200)
    assert runs_payload["issue_identifier"] == "SYM-3"
    assert Enum.map(runs_payload["runs"], & &1["id"]) == ["run-new"]
    assert hd(runs_payload["events"])["summary"] =~ "validation passed"
    refute inspect(runs_payload) =~ "Ecto.Schema.Metadata"
  end

  test "runs route clamps limits and distinguishes invalid, unknown, and unsupported requests" do
    now = DateTime.utc_now()
    FakePersistence.put_issues([%{id: "issue-many", identifier: "SYM-MANY", state: "Done"}])

    FakePersistence.put_runs(
      Enum.map(1..60, fn index ->
        run("run-#{index}", "completed", index, DateTime.add(now, -index, :second), nil)
        |> Map.put(:issue_identifier, "SYM-MANY")
      end)
    )

    assert %{"error" => %{"code" => "missing_parameter"}} =
             build_conn() |> get("/api/v1/runs") |> json_response(400)

    assert %{"error" => %{"code" => "invalid_parameter"}} =
             build_conn() |> get("/api/v1/runs?issue_identifier=SYM-MANY&limit=zero") |> json_response(400)

    assert %{"error" => %{"code" => "history_not_found"}} =
             build_conn() |> get("/api/v1/runs?issue_identifier=SYM-UNKNOWN") |> json_response(404)

    payload = json_response(get(build_conn(), "/api/v1/runs?issue_identifier=SYM-MANY&limit=999"), 200)
    assert length(payload["runs"]) == 50

    assert %{"error" => %{"code" => "method_not_allowed"}} =
             build_conn() |> post("/api/v1/runs", %{}) |> json_response(405)
  end

  test "persistence unavailable and query failures use distinct 503 errors" do
    Application.put_env(:symphony_elixir, :persistence_module, RepoUnavailablePersistence)

    assert %{"error" => %{"code" => "database_unavailable"}} =
             build_conn() |> get("/api/v1/runs?issue_identifier=SYM-3") |> json_response(503)

    Application.put_env(:symphony_elixir, :persistence_module, QueryFailurePersistence)

    assert %{"error" => %{"code" => "database_query_failed"}} =
             build_conn() |> get("/api/v1/runs?issue_identifier=SYM-3") |> json_response(503)
  end

  test "live state remains authoritative and survives history failure" do
    orchestrator_name = Module.concat(__MODULE__, :LiveOrchestrator)
    snapshot = %{empty_snapshot() | running: [running_entry("SYM-LIVE")]}

    start_supervised!(%{
      id: orchestrator_name,
      start: {StaticOrchestrator, :start_link, [[name: orchestrator_name, snapshot: snapshot]]}
    })

    configure_endpoint(orchestrator_name)
    Application.put_env(:symphony_elixir, :persistence_module, RepoUnavailablePersistence)

    payload = json_response(get(build_conn(), "/api/v1/SYM-LIVE"), 200)
    assert payload["status"] == "running"
    assert payload["running"]["session_id"] == "session-live"
    assert payload["history_error"]["code"] == "database_unavailable"
  end

  test "a timed-out history read does not block the memory-backed state endpoint" do
    Application.put_env(:symphony_elixir, :persistence_module, BlockingPersistence)
    Application.put_env(:symphony_elixir, :history_test_owner, self())

    history_request = Task.async(fn -> get(build_conn(), "/api/v1/runs?issue_identifier=SYM-3") end)
    assert_receive {:history_read_blocked, blocked_pid}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state_payload["counts"] == %{"running" => 0, "retrying" => 0, "blocked" => 0}

    assert %{"error" => %{"code" => "database_timeout"}} =
             history_request |> Task.await(2_000) |> json_response(503)

    refute Process.alive?(blocked_pid)
  end

  defp start_test_endpoint(orchestrator_name) do
    configure_endpoint(orchestrator_name)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp configure_endpoint(orchestrator_name) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      rate_limits: %{},
      operator_tasks: %{},
      polling: %{listening?: false, listening_mode: "not_listening"}
    }
  end

  defp running_entry(identifier) do
    %{
      issue_id: "issue-live",
      identifier: identifier,
      state: "In Progress",
      session_id: "session-live",
      turn_count: 1,
      started_at: DateTime.utc_now(),
      last_codex_event: "turn.started",
      last_codex_message: nil,
      last_codex_timestamp: DateTime.utc_now(),
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }
  end

  defp run(id, status, attempt, started_at, failure_reason) do
    %{
      id: id,
      issue_identifier: "SYM-3",
      kind: "issue",
      profile: "implementation",
      status: status,
      attempt: attempt,
      started_at: started_at,
      finished_at: DateTime.add(started_at, 30, :second),
      failure_reason: failure_reason,
      __meta__: %{internal: true}
    }
  end

  defp event(id, event_type, occurred_at, payload) do
    %{
      id: id,
      issue_identifier: "SYM-3",
      run_id: "run-new",
      event_type: event_type,
      occurred_at: occurred_at,
      payload: payload,
      __meta__: %{internal: true}
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
