defmodule SymphonyElixirWeb.Live.ObservabilityFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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

  test "runs page does not render runtime listening controls" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/runs")

    assert html =~ "Runs"
    refute html =~ "Listening:"
    refute html =~ "Start listening"
    refute html =~ "Stop listening"
    refute html =~ "Force stop all agents"
  end

  test "runs page renders data unavailable instead of an empty store when persistence is down" do
    refute Process.whereis(SymphonyElixir.Repo)
    Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/runs")

    assert html =~ "Data unavailable"
    refute html =~ "No persisted runs yet."
  end

  test "runs page loads additional run pages without duplicating rows" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    runs =
      for index <- 1..30 do
        %{
          id: "run-page-#{index}",
          kind: "issue",
          issue_identifier: "MT-PAGE-#{index}",
          status: "completed",
          attempt: 0,
          started_at: DateTime.add(now, -index, :second),
          finished_at: DateTime.add(now, -index, :second),
          inserted_at: DateTime.add(now, -index, :second)
        }
      end

    FakePersistence.put_runs(runs)

    {:ok, view, html} = live(build_conn(), "/runs")

    assert html =~ "MT-PAGE-1"
    refute html =~ "MT-PAGE-30"

    html =
      view
      |> element("button", "Load more runs")
      |> render_click()

    assert html =~ "MT-PAGE-30"
    assert html =~ "All matching runs are loaded."
  end

  test "runs page renders operator runs without issue links" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    FakePersistence.put_runs([
      %{
        id: "run-nap",
        kind: "nap",
        label: "Nap",
        profile: "nap",
        status: "running",
        attempt: 0,
        started_at: now,
        inserted_at: now
      }
    ])

    {:ok, _view, html} = live(build_conn(), "/runs")

    assert html =~ "Nap"
    assert html =~ "run-nap"
    refute html =~ ~s(href="/issues/)
  end

  test "workers page explains centralized mode instead of looking empty" do
    previous_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)

    on_exit(fn -> restore_app_env(:execution_mode, previous_mode) end)

    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/workers")

    assert html =~ "Worker mode inactive"
    assert html =~ "Execution mode is"
    assert html =~ "centralized"
    assert html =~ "Panel-owned dispatch starts Codex"
    assert html =~ "Worker-backed mode"
    assert html =~ "SYMPHONY_EXECUTION_MODE=worker"
    assert html =~ "Worker-backed mode is inactive"
  end

  test "workers page keeps worker-mode registry as primary content" do
    previous_mode = Application.get_env(:symphony_elixir, :execution_mode)
    Application.put_env(:symphony_elixir, :execution_mode, :worker)

    on_exit(fn -> restore_app_env(:execution_mode, previous_mode) end)

    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/workers")

    refute html =~ "Worker mode inactive"
    assert html =~ "Execution mode:"
    assert html =~ "worker"
    assert html =~ "No workers are registered. Worker-backed execution expects compatible workers"
  end

  test "run detail, issue detail, and events pages render persisted observability data" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    run = %{
      id: "run-1",
      issue_identifier: "MT-1",
      workspace_path: "/tmp/workspaces/MT-1",
      status: "failed",
      attempt: 2,
      failure_reason: "boom",
      started_at: now,
      finished_at: now
    }

    workflow = %{
      id: "workflow-1",
      project_id: "fake-project-id",
      source: "web_workflow_settings",
      inserted_at: now,
      raw_workflow_md: workflow_import_raw("git@github.com:org/repo.git")
    }

    FakePersistence.put_runs([run])
    FakePersistence.put_issues([%{identifier: "MT-1", state: "In Progress", title: "Issue detail"}])
    FakePersistence.put_workflow(workflow)

    FakePersistence.put_events([
      %{
        run_id: "run-1",
        issue_identifier: "MT-1",
        event_type: "run.failed",
        payload: %{"api_token" => "secret", "message" => "boom"},
        occurred_at: now
      },
      %{
        run_id: "run-1",
        issue_identifier: "MT-1",
        event_type: "codex.update",
        payload: %{
          event: :startup_failed,
          message: %{reason: :response_error, response_error: %{"message" => "unknown variant reject"}}
        },
        occurred_at: now
      }
    ])

    {:ok, _view, run_html} = live(build_conn(), "/runs/run-1")
    assert run_html =~ "Run Detail"
    assert run_html =~ "MT-1"
    assert run_html =~ "Agent Summary"
    assert run_html =~ "Final message"
    assert run_html =~ "Work performed"
    assert run_html =~ "Last Codex signal"
    refute run_html =~ "Workflow Version"
    refute run_html =~ "ID: workflow-1"
    refute run_html =~ "active: true"
    assert run_html =~ "Session History"
    assert run_html =~ "Run failed"
    assert run_html =~ "Codex startup failed"
    assert run_html =~ "unknown variant reject"
    assert run_html =~ "[REDACTED]"
    refute run_html =~ "secret"

    {:ok, _view, issue_html} = live(build_conn(), "/issues/MT-1")
    assert issue_html =~ "Issue Detail"
    assert issue_html =~ "Issue detail"
    assert issue_html =~ "run-1"

    {:ok, _view, events_html} = live(build_conn(), "/events")
    assert events_html =~ "Events"
    assert events_html =~ "run.failed"

    {:ok, _view, filtered_events_html} = live(build_conn(), "/events?issue_identifier=MT-MISSING")
    assert filtered_events_html =~ "No events recorded"
    refute filtered_events_html =~ "run.failed"
  end

  test "events page normalizes filters and hides low-signal codex notifications" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    FakePersistence.put_events([
      %{
        id: "event-empty-1",
        run_id: "run-events",
        issue_identifier: "MT-EVT",
        event_type: "codex.update",
        payload: %{"event" => "notification", "message" => nil},
        occurred_at: now
      },
      %{
        id: "event-empty-2",
        run_id: "run-events",
        issue_identifier: "MT-EVT",
        event_type: "codex.update",
        payload: %{"event" => "notification", "message" => nil},
        occurred_at: now
      },
      %{
        id: "event-run-failed",
        run_id: "run-events",
        issue_identifier: "MT-EVT",
        event_type: "run.failed",
        payload: %{"failure_reason" => "workspace timeout", "api_token" => "secret"},
        occurred_at: now
      },
      %{
        id: "event-linear",
        run_id: "run-events",
        issue_identifier: "MT-EVT",
        event_type: "linear.state_transition",
        payload: %{"from_state" => "In Progress", "to_state" => "Review"},
        occurred_at: now
      },
      %{
        id: "event-task-failed",
        run_id: "run-events",
        issue_identifier: "SYM-62",
        event_type: "task.failed",
        payload: %{
          "summary" => %{"detail" => "worker failed", "reason" => "timeout"},
          "correlation" => %{"issue_identifier" => "SYM-62"}
        },
        occurred_at: now
      }
    ])

    {:ok, _view, html} = live(build_conn(), "/events")

    assert html =~ "Low-signal rows hidden"
    assert html =~ "2 empty Codex notification rows are hidden"
    assert html =~ "run.failed"
    assert html =~ "workspace timeout"
    assert html =~ "task.failed"
    assert html =~ "worker failed"
    assert html =~ "timeout"
    assert html =~ ~s(href="/issues/MT-EVT")
    assert html =~ ~s(href="/runs/run-events")
    assert html =~ "Raw payload"
    assert html =~ "[REDACTED]"
    refute html =~ "secret"
    refute html =~ "Empty Codex notification; detailed payload was not persisted"

    {:ok, _view, revealed_html} = live(build_conn(), "/events?hide_low_signal=false")
    assert revealed_html =~ "Empty Codex notification; detailed payload was not persisted"

    {:ok, _view, error_html} = live(build_conn(), "/events?severity=error")
    assert error_html =~ "run.failed"
    refute error_html =~ "Linear state moved In Progress"

    {:ok, _view, linear_html} = live(build_conn(), "/events?source=linear")
    assert linear_html =~ "Linear state moved In Progress -&gt; Review"
    refute linear_html =~ "run.failed"
  end

  test "run detail summarizes codex turn history from events" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    FakePersistence.put_runs([
      %{
        id: "run-codex-history",
        issue_identifier: "MT-CODEX-HISTORY",
        workspace_path: "/tmp/workspaces/MT-CODEX-HISTORY",
        status: "completed",
        attempt: 1,
        started_at: now,
        finished_at: now
      }
    ])

    FakePersistence.put_events([
      %{run_id: "run-codex-history", issue_identifier: "MT-CODEX-HISTORY", event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}, occurred_at: now},
      %{run_id: "run-codex-history", issue_identifier: "MT-CODEX-HISTORY", event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}, occurred_at: now},
      %{
        run_id: "run-codex-history",
        issue_identifier: "MT-CODEX-HISTORY",
        event_type: "codex.update",
        payload: %{
          "event" => "notification",
          "message" => %{"method" => "item/tool/call", "params" => %{"tool" => "linear_task_read"}},
          "session_id" => "thread-history"
        },
        occurred_at: now
      },
      %{
        run_id: "run-codex-history",
        issue_identifier: "MT-CODEX-HISTORY",
        event_type: "codex.update",
        payload: %{
          "event" => "notification",
          "message" => %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "Finished the task."}},
          "session_id" => "thread-history"
        },
        occurred_at: now
      }
    ])

    {:ok, _view, html} = live(build_conn(), "/runs/run-codex-history")

    assert html =~ "Agent Summary"
    assert html =~ "Final message"
    assert html =~ "Tools"
    assert html =~ "Session History"
    assert html =~ "dynamic tool call requested (linear_task_read)"
    assert html =~ "linear_task_read x1"
    assert html =~ "agent message streaming: Finished the task."
    assert html =~ "2 empty Codex notifications; detailed payload was not persisted"
    assert html =~ "thread-history"
  end

  test "runs page filters by project query parameter" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    FakePersistence.create_project(%{
      name: "Second Project",
      slug: "second",
      linear_project_slug: "second-project",
      repository_url: "git@github.com:org/repo2.git"
    })

    second_project = FakePersistence.list_projects() |> List.last()

    FakePersistence.put_runs([
      %{
        id: "run-proj-a-1",
        project_id: "fake-project-id",
        kind: "issue",
        issue_identifier: "MT-A-1",
        status: "completed",
        attempt: 0,
        started_at: now,
        finished_at: now,
        inserted_at: now
      },
      %{
        id: "run-proj-b-1",
        project_id: second_project.id,
        kind: "issue",
        issue_identifier: "MT-B-1",
        status: "running",
        attempt: 0,
        started_at: now,
        inserted_at: now
      }
    ])

    {:ok, _view, all_html} = live(build_conn(), "/runs")
    assert all_html =~ "MT-A-1"
    assert all_html =~ "MT-B-1"

    {:ok, _view, filtered_html} = live(build_conn(), "/runs?project=fake-project-id")
    assert filtered_html =~ "MT-A-1"
    refute filtered_html =~ "MT-B-1"

    {:ok, _view, second_html} = live(build_conn(), "/runs?project=#{second_project.id}")
    assert second_html =~ "MT-B-1"
    refute second_html =~ "MT-A-1"
  end

  test "runs page keeps project filter across pagination" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    FakePersistence.create_project(%{
      name: "Second Project",
      slug: "second",
      linear_project_slug: "second-project",
      repository_url: "git@github.com:org/repo2.git"
    })

    second_project = FakePersistence.list_projects() |> List.last()

    runs =
      for index <- 1..30 do
        %{
          id: "run-proj-a-page-#{index}",
          project_id: "fake-project-id",
          kind: "issue",
          issue_identifier: "MT-A-PAGE-#{index}",
          status: "completed",
          attempt: 0,
          started_at: DateTime.add(now, -index, :second),
          finished_at: DateTime.add(now, -index, :second),
          inserted_at: DateTime.add(now, -index, :second)
        }
      end

    FakePersistence.put_runs(
      runs ++
        [
          %{
            id: "run-proj-b-page-1",
            project_id: second_project.id,
            kind: "issue",
            issue_identifier: "MT-B-PAGE-1",
            status: "completed",
            attempt: 0,
            started_at: now,
            finished_at: now,
            inserted_at: now
          }
        ]
    )

    {:ok, view, html} = live(build_conn(), "/runs?project=fake-project-id")

    assert html =~ "MT-A-PAGE-1"
    refute html =~ "MT-A-PAGE-30"
    refute html =~ "MT-B-PAGE-1"

    html =
      view
      |> element("button", "Load more runs")
      |> render_click()

    assert html =~ "MT-A-PAGE-30"
    refute html =~ "MT-B-PAGE-1"
    assert html =~ "All matching runs are loaded."
  end

  test "events page filters by project query parameter" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    FakePersistence.create_project(%{
      name: "Second Project",
      slug: "second",
      linear_project_slug: "second-project",
      repository_url: "git@github.com:org/repo2.git"
    })

    second_project = FakePersistence.list_projects() |> List.last()

    FakePersistence.put_events([
      %{
        id: "event-proj-a-1",
        project_id: "fake-project-id",
        issue_identifier: "MT-EVTA-1",
        event_type: "run.failed",
        payload: %{"failure_reason" => "boom-a"},
        occurred_at: now
      },
      %{
        id: "event-proj-b-1",
        project_id: second_project.id,
        issue_identifier: "MT-EVTB-1",
        event_type: "run.failed",
        payload: %{"failure_reason" => "boom-b"},
        occurred_at: now
      }
    ])

    {:ok, _view, all_html} = live(build_conn(), "/events")
    assert all_html =~ "boom-a"
    assert all_html =~ "boom-b"

    {:ok, _view, filtered_html} = live(build_conn(), "/events?project=fake-project-id")
    assert filtered_html =~ "boom-a"
    refute filtered_html =~ "boom-b"

    {:ok, _view, second_html} = live(build_conn(), "/events?project=#{second_project.id}")
    assert second_html =~ "boom-b"
    refute second_html =~ "boom-a"
  end

  test "workers page tasks filter by project query parameter" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    now = DateTime.utc_now()

    FakePersistence.create_project(%{
      name: "Second Project",
      slug: "second",
      linear_project_slug: "second-project",
      repository_url: "git@github.com:org/repo2.git"
    })

    second_project = FakePersistence.list_projects() |> List.last()

    FakePersistence.put_tasks([
      %{
        id: "task-proj-a-1",
        project_id: "fake-project-id",
        issue_identifier: "MT-TASKA-1",
        status: "queued",
        execution_mode: "worker",
        queued_at: now
      },
      %{
        id: "task-proj-b-1",
        project_id: second_project.id,
        issue_identifier: "MT-TASKB-1",
        status: "queued",
        execution_mode: "worker",
        queued_at: now
      }
    ])

    {:ok, _view, all_html} = live(build_conn(), "/workers")
    assert all_html =~ "MT-TASKA-1"
    assert all_html =~ "MT-TASKB-1"

    {:ok, _view, filtered_html} = live(build_conn(), "/workers?project=fake-project-id")
    assert filtered_html =~ "MT-TASKA-1"
    refute filtered_html =~ "MT-TASKB-1"

    {:ok, _view, second_html} = live(build_conn(), "/workers?project=#{second_project.id}")
    assert second_html =~ "MT-TASKB-1"
    refute second_html =~ "MT-TASKA-1"
  end

  test "runs page renders project switcher with current project selected" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    FakePersistence.create_project(%{
      name: "Second Project",
      slug: "second",
      linear_project_slug: "second-project",
      repository_url: "git@github.com:org/repo2.git"
    })

    second_project = FakePersistence.list_projects() |> List.last()

    {:ok, _view, all_html} = live(build_conn(), "/runs")
    assert all_html =~ "All projects"
    assert all_html =~ "Fake Project"
    assert all_html =~ "Second Project"
    assert all_html =~ ~s(value="/runs?project=fake-project-id")
    assert all_html =~ ~s(value="/runs?project=#{second_project.id}")

    {:ok, _view, filtered_html} = live(build_conn(), "/runs?project=#{second_project.id}")
    assert filtered_html =~ ~s(value="/runs?project=#{second_project.id}")
    assert filtered_html =~ "Second Project"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp workflow_import_raw(repository_url) do
    """
    ---
    tracker:
      kind: linear
      endpoint: "https://api.linear.app/graphql"
      project_slug: "project"
      active_states: ["Refining", "Ready", "In Progress"]
      terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
    polling:
      interval_ms: 30000
    project:
      repository_url: "#{repository_url}"
      default_branch: "main"
      checkout_depth: 1
      setup_commands: ["mix deps.get"]
      cleanup_commands: []
    workspace:
      root: "/tmp/imported-workspaces"
    agent:
      max_turns: 20
    codex:
      command: "codex app-server"
      thread_sandbox: "workspace-write"
    server:
      host: "127.0.0.1"
      port: 4000
    workflow:
      states:
        Refining:
          profile: refinement
        Ready:
          profile: implementation
        In Progress:
          profile: implementation
      human_review_states: ["Needs Refinement Review", "Ready to Merge"]
      allowed_transitions:
        - {from: Ready, to: In Progress, actor: codex, profile: implementation}
        - {from: In Progress, to: Ready to Merge, actor: codex, profile: implementation}
        - {from: Ready to Merge, to: In Progress, actor: human, profile: implementation}
      tool_policy:
        linear:
          exposed_tools: ["linear_task_read", "linear_task_update"]
          raw_graphql: false
    profiles:
      refinement:
        name: "Refinement"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Refine the task."}
        allowed_updates: {description: true, comment: true, result: false, target_states: ["Needs Refinement Review"]}
      implementation:
        name: "Implementation"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Implement the task."}
        allowed_updates: {description: false, comment: true, result: true, target_states: ["In Progress", "Ready to Merge"]}
    ---

    Imported workflow prompt.
    """
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
