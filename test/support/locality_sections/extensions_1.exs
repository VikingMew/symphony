# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.TestSupport.LocalitySections.Extensions1 do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.ExtensionsTest.FakeLinearClient
  alias SymphonyElixir.ExtensionsTest.SlowOrchestrator
  alias SymphonyElixir.ExtensionsTest.StaticOrchestrator
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote context: __CALLER__.module do
      use SymphonyElixir.TestSupport

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

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
          {:noreply, state}
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

        def handle_call({:clear_blocking_decision, issue_identifier}, _from, state) do
          blocked = Keyword.fetch!(state, :snapshot).blocked

          status =
            if Enum.any?(blocked, fn entry ->
                 entry.identifier == issue_identifier and
                   is_map(Map.get(entry, :blocking_decision))
               end),
               do: "cleared",
               else: "already_cleared"

          updated_blocked =
            Enum.reject(blocked, fn entry ->
              entry.identifier == issue_identifier and
                is_map(Map.get(entry, :blocking_decision))
            end)

          if owner = Keyword.get(state, :owner),
            do: send(owner, {:blocking_decision_cleared, issue_identifier})

          state =
            Keyword.update!(state, :snapshot, fn snapshot ->
              Map.put(snapshot, :blocked, updated_blocked)
            end)

          {:reply, %{status: status, issue_identifier: issue_identifier}, state}
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
        assert Tracker.adapter() == Adapter
        assert {:ok, [:candidate]} = Tracker.fetch_candidate_issues()
        assert_receive :fetch_candidate_issues_called
        assert {:ok, [" in progress ", 42]} = Tracker.fetch_issues_by_states([" in progress ", 42])
        assert_receive {:fetch_issues_by_states_called, [" in progress ", 42]}
        assert {:ok, ["issue-1"]} = Tracker.fetch_issue_states_by_ids(["issue-1"])
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
                     "runtime_seconds" => nil,
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
                     "run_id" => nil,
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
                 "environment_failure_circuit" => %{
                   "active" => false,
                   "consecutive_failures" => 0,
                   "distinct_issue_count" => 0,
                   "issue_identifiers" => [],
                   "status" => "allow",
                   "threshold" => 3,
                   "triggered_at" => nil,
                   "triggering_fingerprint" => nil,
                   "window_ms" => 1_800_000
                 },
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
                 "worker_api" => %{"heartbeat_failed_attempts" => 0},
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
                 "error" => %{"code" => "issue_not_found", "message" => "Issue not found", "retryable" => false}
               }

        conn = post(build_conn(), "/api/v1/refresh", %{})

        assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
                 json_response(conn, 202)
      end

      test "phoenix observability api preserves 405, 404, and unavailable behavior" do
        unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
        start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

        assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
                 %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed", "retryable" => false}}

        assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
                 %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed", "retryable" => false}}

        assert json_response(post(build_conn(), "/", %{}), 405) ==
                 %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed", "retryable" => false}}

        assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
                 %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed", "retryable" => false}}

        assert json_response(post(build_conn(), "/api/v1/runs", %{}), 405) ==
                 %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed", "retryable" => false}}

        assert json_response(get(build_conn(), "/unknown"), 404) ==
                 %{"error" => %{"code" => "not_found", "message" => "Route not found", "retryable" => false}}

        state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

        assert state_payload ==
                 %{
                   "generated_at" => state_payload["generated_at"],
                   "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable", "retryable" => true}
                 }

        assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
                 %{
                   "error" => %{
                     "code" => "orchestrator_unavailable",
                     "message" => "Orchestrator is unavailable",
                     "retryable" => true
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
                   "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out", "retryable" => true}
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
    end
  end
end
