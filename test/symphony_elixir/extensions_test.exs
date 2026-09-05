defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call(:start_listening, _from, state) do
      state = update_snapshot_listening(state, true, "listening_all")
      {:reply, %{listening?: true, listening_mode: "listening_all", changed_at: DateTime.utc_now()}, state}
    end

    def handle_call(:start_refine_only_listening, _from, state) do
      state = update_snapshot_listening(state, true, "listening_refine_only")
      {:reply, %{listening?: true, listening_mode: "listening_refine_only", changed_at: DateTime.utc_now()}, state}
    end

    def handle_call(:stop_listening, _from, state) do
      state = update_snapshot_listening(state, false, "not_listening")
      {:reply, %{listening?: false, listening_mode: "not_listening", changed_at: DateTime.utc_now()}, state}
    end

    def handle_call(:force_stop_all, _from, state) do
      state = update_snapshot_listening(state, false, "not_listening")
      {:reply, %{listening?: false, listening_mode: "not_listening", stopped_count: 0, rollback_results: []}, state}
    end

    def handle_call({:request_operator_task, kind}, _from, state) do
      handle_operator_task_request(kind, nil, state)
    end

    def handle_call({:request_operator_task, kind, project_id}, _from, state) do
      handle_operator_task_request(kind, project_id, state)
    end

    defp handle_operator_task_request(kind, project_id, state) do
      failure_reason = Keyword.get(state, :operator_failure)

      task = %{
        kind: to_string(kind),
        project_id: project_id,
        status: if(failure_reason, do: "failed", else: "running"),
        run_id: "operator-#{kind}-1",
        requested_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        queued_at: nil,
        started_at: if(failure_reason, do: nil, else: DateTime.utc_now() |> DateTime.to_iso8601()),
        finished_at: if(failure_reason, do: DateTime.utc_now() |> DateTime.to_iso8601()),
        failure_reason: failure_reason,
        summary:
          if(failure_reason,
            do: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason},
            else: %{created: 0, skipped: 0, failed: 0, issues: []}
          )
      }

      if owner = Keyword.get(state, :owner), do: send(owner, {:operator_task_requested, kind, project_id})

      state =
        Keyword.update!(state, :snapshot, fn snapshot ->
          update_in(snapshot, [:operator_tasks], fn tasks ->
            Map.put(tasks || %{}, kind, task)
          end)
        end)

      {:reply, Map.put(task, :accepted, true), state}
    end

    defp update_snapshot_listening(state, listening?, mode) do
      Keyword.update!(state, :snapshot, fn snapshot ->
        Map.put(snapshot, :polling, %{listening?: listening?, listening_mode: mode})
      end)
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads active database workflow and can read without the server process" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = WorkflowStore.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, WorkflowStore.current())
    end)

    third_workflow = Path.join([Path.dirname(Workflow.workflow_file_path()), "third", "workflow.yml"])
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    assert {:ok, %{workflow: %{prompt: "Third prompt"}, source: %{type: :database}}} = WorkflowStore.current_with_source()
    assert {:error, {:refresh_failed, :cache_unavailable}} = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init uses setup required when no workflow exists" do
    FakePersistence.reset!()

    assert {:ok, state} = WorkflowStore.init([])
    assert state.workflows == %{}
    assert state.source.type == :setup_required
  end

  test "workflow store start_link and poll callback use database workflow" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join([Path.dirname(existing_path), "manual", "workflow.yml"])

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt after poll")
    state = :sys.get_state(manual_pid)
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    workflow = Map.get(returned_state.workflows, returned_state.default_project_id)
    assert workflow.prompt == "Manual workflow prompt after poll"
    assert returned_state.source.type == :database
    assert_receive :poll, 2_500

    GenServer.stop(manual_pid, :normal)
    assert_eventually(fn -> is_nil(Process.whereis(WorkflowStore)) end)
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to the linear adapter with fake Linear inputs" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert Config.settings!().tracker.kind == "linear"
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert {:ok, [:candidate]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called
    assert {:ok, [" in progress ", 42]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert_receive {:fetch_issues_by_states_called, [" in progress ", 42]}
    assert {:ok, ["issue-1"]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "session_history" => [],
                 "session_history_total_count" => 0,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-blocked",
                 "reason" => "turn_input_required",
                 "detail" => "turn blocked: waiting for user input",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "session_history" => [],
                 "session_history_total_count" => 0
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "rate_limit_status" => %{
               "active_sessions" => 1,
               "last_codex_event" => "notification",
               "last_codex_message" => "rendered",
               "last_codex_timestamp" => nil,
               "note" => "Upstream Codex rate-limit snapshot received.",
               "debug_payload" => nil,
               "gate" => nil,
               "observation" => nil,
               "snapshot" => %{"primary" => %{"remaining" => 11}},
               "status" => "available",
               "token_totals" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12, "seconds_running" => 42.5}
             },
             "linear_status" => %{
               "badge_class" => "status-badge status-info",
               "candidate_count" => nil,
               "detail" => "Open Linear diagnostics to run connectivity and state checks.",
               "href" => "/diagnostics/linear",
               "label" => "Linear unknown",
               "project_slug" => "project",
               "ran_at" => nil,
               "status" => "unknown"
             },
             "operator_tasks" => %{
               "nap" => %{"status" => "idle"},
               "day_dreaming" => %{"status" => "idle"}
             },
             "polling" => %{"listening?" => false, "listening_mode" => "not_listening"}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "blocked" => nil,
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{},
             "persisted_issue" => nil,
             "latest_run" => nil,
             "recent_runs" => [],
             "timeline" => []
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "blocked" => %{"reason" => "turn_input_required", "detail" => "turn blocked: waiting for user input"}
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/runs", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "resize: none;"
    assert dashboard_css =~ "overflow: auto;"
    assert dashboard_css =~ ".workflow-textbox-compact"
    assert dashboard_css =~ ".workflow-textbox-medium"
    assert dashboard_css =~ ".workflow-textbox-profile"
    assert dashboard_css =~ ".workflow-textbox-prompt"
    assert dashboard_css =~ ".settings-content-card"
    assert dashboard_css =~ ".settings-action-row"
    assert dashboard_css =~ ".agent-prompt-editor"
    assert dashboard_css =~ ".agent-settings-form .agent-field"
    assert dashboard_css =~ ".agent-settings-form .agent-field-label"
    assert dashboard_css =~ ".workflow-profile-field-grid"
    assert dashboard_css =~ ".profile-field-group"
    assert dashboard_css =~ ".profile-prompt-layout"
    assert dashboard_css =~ "height: 2.75rem;"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Listening:"
    assert html =~ "disabled"
    assert html =~ "Start listening"
    assert html =~ "Stop listening"
    assert html =~ "Force stop all agents"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "Linear unknown"
    assert html =~ ~s(href="/diagnostics/linear")
    assert html =~ "Upstream Codex rate-limit snapshot received."
    assert html =~ "remaining"
    refute html =~ "Raw rate-limit payload"
    refute html =~ "Event log"
    refute html =~ "log-table"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard renders scrubbed raw rate-limit debug payload only for unrecognized updates" do
    orchestrator_name = Module.concat(__MODULE__, :RateLimitDebugOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, nil)
      |> Map.put(:rate_limit_observation, %{
        status: :unrecognized,
        debug_payload: %{
          source_path: "update.payload.params.rateLimits",
          method: "account/rateLimits/updated",
          reason: "No recognized shape",
          payload: [%{"authorization" => "[REDACTED]", "unexpected" => true}],
          truncated: false
        }
      })

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Raw rate-limit payload"
    assert html =~ "update.payload.params.rateLimits"
    assert html =~ "account/rateLimits/updated"
    assert html =~ "[REDACTED]"
    refute html =~ "Bearer"
  end

  test "dashboard renders observed parsed codex rate-limit payload" do
    orchestrator_name = Module.concat(__MODULE__, :ParsedRateLimitOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, %{
        "limit_id" => "codex",
        "plan_type" => "pro",
        "primary" => %{"used_percent" => 65, "window_duration_mins" => 300, "resets_at" => 1_779_341_757},
        "secondary" => %{"used_percent" => 18, "window_duration_mins" => 10_080, "resets_at" => 1_779_848_319}
      })

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "available"
    assert html =~ "Plan pro"
    assert html =~ "Limit codex"
    assert html =~ "65%"
    assert html =~ "18%"
    assert html =~ "5h"
    assert html =~ "1w"
    refute html =~ "unrecognized"
    refute html =~ "Raw rate-limit payload"
  end

  test "dashboard controls listening status" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardListeningOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        owner: self(),
        refresh: %{queued: false, coalesced: false, requested_at: DateTime.utc_now(), operations: []}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Listening:"
    assert html =~ "disabled"
    assert html =~ "Listen refinement only"
    assert html =~ "Take a nap"
    assert html =~ "Day dreaming"
    assert html =~ "nap:"
    assert html =~ "Fake Project (fake)"

    start_html =
      view
      |> element("button[phx-click='start_listening']")
      |> render_click()

    assert start_html =~ "Listening:"
    assert start_html =~ "all active work"

    refine_html =
      view
      |> element("button[phx-click='start_refine_only_listening']")
      |> render_click()

    assert refine_html =~ "Listening:"
    assert refine_html =~ "refinement only"

    stop_html =
      view
      |> element("button[phx-click='stop_listening']")
      |> render_click()

    assert stop_html =~ "Listening:"
    assert stop_html =~ "disabled"

    nap_html =
      view
      |> form("#request-nap-form", %{"project_id" => "fake-project-id"})
      |> render_submit()

    assert nap_html =~ "nap:"
    assert nap_html =~ "running"
    assert_receive {:operator_task_requested, :nap, "fake-project-id"}

    day_dreaming_html =
      view
      |> form("#request-day-dreaming-form", %{"project_id" => "fake-project-id"})
      |> render_submit()

    assert day_dreaming_html =~ "day dreaming:"
    assert day_dreaming_html =~ "running"
    assert_receive {:operator_task_requested, :day_dreaming, "fake-project-id"}
  end

  test "dashboard surfaces operator project workflow errors" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOperatorFailureOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        owner: self(),
        operator_failure: "no workflow for project: fake-project-id"
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view
      |> form("#request-nap-form", %{"project_id" => "fake-project-id"})
      |> render_submit()

    assert_receive {:operator_task_requested, :nap, "fake-project-id"}
    assert html =~ "Take a nap failed: no workflow for project: fake-project-id"
    assert html =~ "failed"
  end

  test "dashboard keeps session history expanded across live updates" do
    orchestrator_name = Module.concat(__MODULE__, :SessionHistoryOrchestrator)

    snapshot =
      update_in(static_snapshot().running, fn [entry] ->
        [
          entry
          |> Map.put(:session_history, [
            %{
              event: :run_started,
              label: "Run started",
              detail: "Started from In Progress",
              severity: :info,
              at: DateTime.utc_now(),
              metadata: %{}
            }
          ])
          |> Map.put(:session_history_total_count, 125)
        ]
      end)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: false, coalesced: false, requested_at: DateTime.utc_now(), operations: []}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Session history (1 rows from 125 events)"
    refute html =~ "<details open"

    view
    |> element(~s(summary[phx-value-key="issue-http"]))
    |> render_click()

    assert render(view) =~ "<details open"

    updated_snapshot =
      update_in(snapshot.running, fn [entry] ->
        [
          %{
            entry
            | last_codex_message: "updated while expanded",
              session_history:
                entry.session_history ++
                  [
                    %{
                      event: :notification,
                      label: "Codex update",
                      detail: "updated while expanded",
                      severity: :info,
                      at: DateTime.utc_now(),
                      metadata: %{}
                    }
                  ],
              session_history_total_count: 126
          }
        ]
      end)

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      html = render(view)
      html =~ "<details open" and html =~ "Session history (2 rows from 126 events)"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "dashboard liveview renders database faults as unavailable instead of zero metrics" do
    snapshot =
      static_snapshot()
      |> Map.put(:config_error, %{
        reason: ":repo_unavailable",
        message: "database repository is unavailable",
        unavailable: true
      })

    orchestrator_name = Module.concat(__MODULE__, :DatabaseUnavailableDashboardOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Data unavailable"
    assert html =~ "database_unavailable"
    refute html =~ "Active issue sessions in the current runtime."
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server starts from raw server config when workflow policy is invalid" do
    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "127.0.0.1",
      workflow_policy: %{
        "states" => %{
          "Ready" => %{"profile" => "implementation"}
        },
        "human_review_states" => ["Needs Implementation Review"],
        "allowed_transitions" => [
          %{"from" => "Needs Implementation Review", "to" => "Ready", "actor" => "human"}
        ]
      }
    )

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :InvalidWorkflowHttpServerOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    start_supervised!({HttpServer, port: 0, orchestrator: orchestrator_name, snapshot_timeout_ms: 50})

    assert is_integer(wait_for_bound_port())
  end

  test "application support processes ignore persisted workflow policy during boot" do
    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "127.0.0.1",
      observability_enabled: true,
      workflow_policy: %{
        "states" => %{
          "Ready" => %{"profile" => "implementation"}
        },
        "human_review_states" => ["Needs Implementation Review"],
        "allowed_transitions" => [
          %{"from" => "Needs Implementation Review", "to" => "Ready", "actor" => "human"}
        ]
      }
    )

    orchestrator_name = Module.concat(__MODULE__, :InvalidWorkflowPolicyBootOrchestrator)
    dashboard_name = Module.concat(__MODULE__, :InvalidWorkflowPolicyBootDashboard)

    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)
    {:ok, dashboard_pid} = StatusDashboard.start_link(name: dashboard_name, enabled: true, refresh_ms: 60_000)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
      if Process.alive?(dashboard_pid), do: Process.exit(dashboard_pid, :normal)
    end)

    assert %{polling: %{listening?: false}, config_error: nil} =
             GenServer.call(orchestrator_pid, :snapshot)

    assert Process.alive?(dashboard_pid)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          session_id: "thread-blocked",
          reason: :turn_input_required,
          detail: "turn blocked: waiting for user input",
          blocked_at: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      polling: %{listening?: false, listening_mode: "not_listening"},
      operator_tasks: %{
        nap: %{status: "idle"},
        day_dreaming: %{status: "idle"}
      }
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
