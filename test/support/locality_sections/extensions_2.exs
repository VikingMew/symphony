# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.ExtensionsTest.Sections.Extensions2 do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias SymphonyElixir.Linear.Adapter
      alias SymphonyElixir.TestSupport.FakePersistence

      import ExUnit.CaptureLog
      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Health
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.TestSupport.FakePersistence
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Worker.HeartbeatMetrics
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          ensure_panel_children_running!: 0,
          panel_supervisor_running?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      alias SymphonyElixir.ExtensionsTest.{FakeLinearClient, SlowOrchestrator, StaticOrchestrator}

      test "dashboard liveview renders and refreshes over pubsub" do
        orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
        snapshot = static_snapshot()

        {:ok, orchestrator_pid} =
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
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

        Elixir.SymphonyElixir.StatusDashboard.notify_update()

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

        {:ok, _pid} =
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
            name: orchestrator_name,
            snapshot: snapshot
          )

        start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

        {:ok, _view, html} = live(build_conn(), "/")

        assert html =~ "Raw rate-limit payload"
        assert html =~ "update.payload.params.rateLimits"
        assert html =~ "account/rateLimits/updated"
        assert html =~ "[REDACTED]"
      end

      test "dashboard renders observed parsed codex rate-limit payload" do
        orchestrator_name = Module.concat(__MODULE__, :ParsedRateLimitOrchestrator)

        snapshot =
          static_snapshot()
          |> Map.put(:rate_limits, %{
            "limit_id" => "codex",
            "plan_type" => "pro",
            "primary" => %{
              "used_percent" => 65,
              "window_duration_mins" => 300,
              "resets_at" => 1_779_341_757
            },
            "secondary" => %{
              "used_percent" => 18,
              "window_duration_mins" => 10_080,
              "resets_at" => 1_779_848_319
            }
          })

        {:ok, _pid} =
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
            name: orchestrator_name,
            snapshot: snapshot
          )

        start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

        {:ok, _view, html} = live(build_conn(), "/")

        assert html =~ "available"
        assert html =~ "Plan pro"
        assert html =~ "Limit codex"
        assert html =~ "65%"
        assert html =~ "18%"
        assert html =~ "5h"
        assert html =~ "1w"
      end

      test "dashboard controls listening status" do
        orchestrator_name = Module.concat(__MODULE__, :DashboardListeningOrchestrator)

        {:ok, _orchestrator_pid} =
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
            name: orchestrator_name,
            snapshot: static_snapshot(),
            owner: self(),
            refresh: %{
              queued: false,
              coalesced: false,
              requested_at: DateTime.utc_now(),
              operations: []
            }
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
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
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
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
            name: orchestrator_name,
            snapshot: snapshot,
            refresh: %{
              queued: false,
              coalesced: false,
              requested_at: DateTime.utc_now(),
              operations: []
            }
          )

        start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

        {:ok, view, html} = live(build_conn(), "/")
        assert html =~ "Session history (1 rows from 125 events)"

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

        Elixir.SymphonyElixir.StatusDashboard.notify_update()

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

        {:ok, _pid} =
          Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator.start_link(
            name: orchestrator_name,
            snapshot: snapshot
          )

        start_test_endpoint(orchestrator: orchestrator_name)

        {:ok, _view, html} = live(build_conn(), "/")

        assert html =~ "Data unavailable"
        assert html =~ "database_unavailable"
      end

      test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
        spec = Elixir.SymphonyElixir.HttpServer.child_spec(port: 0)
        assert spec.id == Elixir.SymphonyElixir.HttpServer
        assert spec.start == {Elixir.SymphonyElixir.HttpServer, :start_link, [[port: 0]]}

        assert :ignore = Elixir.SymphonyElixir.HttpServer.start_link(port: nil)
        assert Elixir.SymphonyElixir.HttpServer.bound_port() == nil

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

        static_opts = [name: orchestrator_name, snapshot: snapshot, refresh: refresh]
        static_orchestrator = {Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator, static_opts}

        start_supervised!(static_orchestrator)

        start_supervised!({Elixir.SymphonyElixir.HttpServer, server_opts})

        port = wait_for_bound_port()
        assert port == Elixir.SymphonyElixir.HttpServer.bound_port()

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

        assert {:error, _reason} =
                 Elixir.SymphonyElixir.HttpServer.start_link(host: "bad host", port: 0)
      end

      test "http server starts from raw server config when workflow policy is invalid" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
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

        static_orchestrator =
          {Elixir.SymphonyElixir.ExtensionsTest.StaticOrchestrator, name: orchestrator_name, snapshot: snapshot}

        start_supervised!(static_orchestrator)

        http_server =
          {Elixir.SymphonyElixir.HttpServer, port: 0, orchestrator: orchestrator_name, snapshot_timeout_ms: 50}

        start_supervised!(http_server)

        assert is_integer(wait_for_bound_port())
      end

      test "application support processes ignore persisted workflow policy during boot" do
        write_workflow_file!(Elixir.SymphonyElixir.Workflow.workflow_file_path(),
          server_host: "127.0.0.1",
          observability_enabled: true,
          project_repository_url: "git@example.com:org/repo.git",
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

        {:ok, orchestrator_pid} = Elixir.SymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

        {:ok, dashboard_pid} =
          Elixir.SymphonyElixir.StatusDashboard.start_link(
            name: dashboard_name,
            enabled: true,
            refresh_ms: 60_000
          )

        on_exit(fn ->
          if Process.alive?(orchestrator_pid) do
            Process.exit(orchestrator_pid, :normal)
          end

          if Process.alive?(dashboard_pid) do
            Process.exit(dashboard_pid, :normal)
          end
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
              due_in_ms: 2000,
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
          environment_failure_circuit: SymphonyElixir.EnvironmentFailureCircuit.allow_snapshot(),
          polling: %{listening?: false, listening_mode: "not_listening"},
          operator_tasks: %{
            nap: %{status: "idle"},
            day_dreaming: %{status: "idle"}
          }
        }
      end

      defp wait_for_bound_port do
        assert_eventually(fn ->
          is_integer(Elixir.SymphonyElixir.HttpServer.bound_port())
        end)

        Elixir.SymphonyElixir.HttpServer.bound_port()
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

      defp assert_eventually(_fun, 0) do
        flunk("condition not met in time")
      end

      defp ensure_workflow_store_running do
        if Process.whereis(Elixir.SymphonyElixir.WorkflowStore) do
          :ok
        else
          case Supervisor.restart_child(SymphonyElixir.Supervisor, Elixir.SymphonyElixir.WorkflowStore) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end
    end
  end
end
