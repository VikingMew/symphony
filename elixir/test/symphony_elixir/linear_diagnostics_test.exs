defmodule SymphonyElixir.LinearDiagnosticsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.{Diagnostics, Discovery}
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.{Workflow, WorkflowStore}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeClient do
    @moduledoc false

    alias SymphonyElixir.Linear.Issue

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def graphql(_query, variables, opts) do
      fake = Application.get_env(:symphony_elixir, :linear_diagnostics_fake, %{})

      case Map.get(fake, Keyword.get(opts, :operation_name)) do
        nil -> {:ok, default_response(Keyword.get(opts, :operation_name), variables)}
        {:error, reason} -> {:error, reason}
        response when is_function(response, 2) -> {:ok, response.(variables, opts)}
        response when is_function(response, 1) -> {:ok, response.(variables)}
        response -> {:ok, response}
      end
    end

    @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_candidate_issues do
      fake = Application.get_env(:symphony_elixir, :linear_diagnostics_fake, %{})
      Map.get(fake, :candidate_result, {:ok, []})
    end

    defp default_response("SymphonyLinearDiagnosticsViewer", _variables) do
      %{"data" => %{"viewer" => %{"id" => "viewer-1", "name" => "Ops User", "email" => "ops@example.test"}}}
    end

    defp default_response("SymphonyLinearDiagnosticsTeams", _variables) do
      %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{"id" => "team-1", "name" => "Platform"},
              %{"id" => "team-2", "name" => "Apps"}
            ]
          }
        }
      }
    end

    defp default_response("SymphonyLinearDiagnosticsProject", _variables) do
      %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-1",
                "name" => "Project",
                "slugId" => "project",
                "url" => "https://linear.app/project/project",
                "teams" => %{
                  "nodes" => [
                    %{
                      "id" => "team-1",
                      "name" => "Team",
                      "states" => %{
                        "nodes" => [
                          %{"name" => "Refining"},
                          %{"name" => "Needs Refinement Review"},
                          %{"name" => "Ready"},
                          %{"name" => "In Progress"},
                          %{"name" => "Needs Implementation Review"},
                          %{"name" => "Ready to Merge"},
                          %{"name" => "Merging"},
                          %{"name" => "Done"},
                          %{"name" => "Cancelled"},
                          %{"name" => "Canceled"},
                          %{"name" => "Duplicate"}
                        ]
                      }
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    end

    defp default_response("SymphonyLinearDiscoveryViewer", _variables) do
      %{
        "data" => %{
          "viewer" => %{"id" => "viewer-1", "name" => "Ops User", "email" => "ops@example.test"}
        }
      }
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
                    %{"id" => "state-review", "name" => "Needs Implementation Review", "type" => "started"},
                    %{"id" => "state-done", "name" => "Done", "type" => "completed"},
                    %{"id" => "state-canceled", "name" => "Canceled", "type" => "canceled"}
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
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_auth = Application.get_env(:symphony_elixir, :auth)
    previous_client = Application.get_env(:symphony_elixir, :linear_diagnostics_client_module)
    previous_fake = Application.get_env(:symphony_elixir, :linear_diagnostics_fake)
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    Application.put_env(:symphony_elixir, :linear_diagnostics_client_module, FakeClient)

    on_exit(fn ->
      restore_app_env(SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:auth, previous_auth)
      restore_app_env(:linear_diagnostics_client_module, previous_client)
      restore_app_env(:linear_diagnostics_fake, previous_fake)
      restore_app_env(:persistence_module, previous_persistence)
    end)

    :ok
  end

  test "diagnostics reports healthy api project states and candidate issues" do
    issue = %Issue{
      id: "issue-1",
      identifier: "LIN-1",
      title: "Wire Linear diagnostics",
      state: "Ready",
      assignee_id: "user-1",
      labels: ["backend", "ops"],
      blocked_by: [%{id: "blocker-1", identifier: "LIN-0", state: "Done"}],
      updated_at: ~U[2026-05-01 10:00:00Z],
      url: "https://linear.app/issue/LIN-1"
    }

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{candidate_result: {:ok, [issue]}})

    diagnostics = Diagnostics.run()

    assert diagnostics.run_id =~ "linear-diagnostics-"
    assert %DateTime{} = diagnostics.ran_at
    assert Enum.any?(diagnostics.log, &(&1.step == "runtime" and &1.status == :ok))
    assert Enum.any?(diagnostics.log, &(&1.step == "api" and &1.status == :ok))
    assert Enum.any?(diagnostics.log, &(&1.step == "teams" and &1.status == :ok))
    assert Enum.any?(diagnostics.log, &(&1.step == "project" and &1.status == :ok))
    assert Enum.any?(diagnostics.log, &(&1.step == "states" and &1.status == :ok))
    assert Enum.any?(diagnostics.log, &(&1.step == "candidates" and &1.status == :ok))
    assert diagnostics.config.tracker_kind == "linear"
    assert diagnostics.config.project_slug == "project"
    assert diagnostics.config.token_configured
    assert diagnostics.config.token.configured
    assert diagnostics.config.token.source == "env:LINEAR_API_KEY"
    assert diagnostics.config.token.length == 5
    assert diagnostics.config.token.sha256_prefix == "3c469e9d6c58"
    assert diagnostics.probes.api.status == :ok
    assert diagnostics.probes.teams.status == :ok
    assert diagnostics.probes.teams.data.team_count == 2
    assert %{id: "team-1", name: "Platform"} in diagnostics.probes.teams.data.teams
    assert diagnostics.probes.project.status == :ok
    assert diagnostics.probes.states.status == :ok
    assert diagnostics.probes.candidates.status == :ok
    assert [%{identifier: "LIN-1", state: "Ready", assignee: "assigned"}] = diagnostics.issues
  end

  test "diagnostics gives setup-required next steps" do
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()
    assert :ok = WorkflowStore.force_reload()

    diagnostics = Diagnostics.run()

    assert diagnostics.runtime_source.type == "setup_required"
    assert diagnostics.probes.api.status == :error
    assert diagnostics.probes.api.title == "Setup required"
    assert diagnostics.probes.api.detail =~ "Open Settings / Workflow"
    refute diagnostics.probes.api.detail =~ "Settings / Projects"
    refute diagnostics.probes.api.detail =~ "Linear project slug"
    assert diagnostics.probes.teams.detail == "Skipped because no active workflow version is configured."
    refute diagnostics.probes.api.detail =~ "Cannot load active workflow config"
  end

  test "diagnostics setup-required next steps include only missing project settings" do
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()
    assert {:ok, _project} = FakePersistence.update_project("fake-project-id", %{linear_project_slug: nil, repository_url: nil})
    assert :ok = WorkflowStore.force_reload()

    diagnostics = Diagnostics.run()

    assert diagnostics.runtime_source.type == "setup_required"
    assert diagnostics.probes.api.title == "Setup required"
    assert diagnostics.probes.api.detail =~ "Open Settings / Workflow"
    assert diagnostics.probes.api.detail =~ "Open Settings / Projects"
    assert diagnostics.probes.api.detail =~ "the Linear project slug"
    assert diagnostics.probes.api.detail =~ "the repository URL"
    assert diagnostics.probes.teams.detail == "Skipped because setup is not complete."
  end

  test "database workflow source controls diagnostics project slug through fake persistence" do
    previous_source = Application.get_env(:symphony_elixir, :workflow_source)

    on_exit(fn -> restore_app_env(:workflow_source, previous_source) end)

    raw = """
    ---
    tracker:
      kind: linear
      endpoint: "https://api.linear.app/graphql"
      api_key: "token"
      project_slug: "db-project"
      active_states: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"]
      terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
    polling:
      interval_ms: 30000
    workspace:
      root: "/tmp/symphony-workspaces"
    agent:
      max_concurrent_agents: 1
      max_turns: 20
    codex:
      command: "codex app-server"
      thread_sandbox: "workspace-write"
    server:
      host: "127.0.0.1"
      port: 4000
    ---

    You are a database diagnostics agent.
    """

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()
    {:ok, project} = FakePersistence.default_project()
    assert {:ok, _version} = FakePersistence.import_workflow(project, raw, "web_workflow_settings")
    Application.put_env(:symphony_elixir, :workflow_source, :database)
    assert :ok = WorkflowStore.force_reload()

    diagnostics = Diagnostics.run()

    assert diagnostics.runtime_source.type == "database"
    assert diagnostics.config.project_slug == "db-project"
  end

  test "diagnostics reports missing token without exposing token values" do
    System.delete_env("LINEAR_API_KEY")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    diagnostics = Diagnostics.run()
    rendered = inspect(diagnostics)

    assert diagnostics.config.token_configured == false
    assert diagnostics.config.token.configured == false
    assert diagnostics.config.token.source == "missing env:LINEAR_API_KEY"
    assert diagnostics.config.token.length == 0
    assert diagnostics.config.token.sha256_prefix == "n/a"
    assert diagnostics.probes.api.status == :error
    assert diagnostics.probes.api.detail =~ "token is missing"
    assert Enum.any?(diagnostics.log, &(&1.step == "api" and &1.status == :error and &1.message =~ "token is missing"))
    refute rendered =~ "Authorization"
    refute rendered =~ "secret"
  end

  test "diagnostics marks missing configured workflow states" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiagnosticsProject" => %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-1",
                "name" => "Project",
                "slugId" => "project",
                "teams" => %{"nodes" => [%{"name" => "Team", "states" => %{"nodes" => [%{"name" => "Ready"}]}}]}
              }
            ]
          }
        }
      }
    })

    diagnostics = Diagnostics.run()

    assert diagnostics.probes.states.status == :error
    assert diagnostics.probes.states.detail =~ "Missing Linear states:"
    assert "Refining" in diagnostics.probes.states.data.missing_active
    assert "Done" in diagnostics.probes.states.data.missing_terminal
    assert Enum.any?(diagnostics.log, &(&1.step == "states" and &1.status == :error))
  end

  test "diagnostics page explains where missing Linear states are configured" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiagnosticsProject" => %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-1",
                "name" => "Project",
                "slugId" => "project",
                "teams" => %{
                  "nodes" => [
                    %{
                      "name" => "Team",
                      "states" => %{
                        "nodes" => [
                          %{"name" => "Refining"},
                          %{"name" => "Needs Refinement Review"},
                          %{"name" => "Ready"},
                          %{"name" => "In Progress"},
                          %{"name" => "Ready to Merge"},
                          %{"name" => "Merging"},
                          %{"name" => "Done"},
                          %{"name" => "Canceled"},
                          %{"name" => "Duplicate"}
                        ]
                      }
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    })

    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/diagnostics/linear")

    assert html =~ "Workflow State Fixes"
    assert html =~ "Settings validation checks local structure"
    assert html =~ "Cancelled"
    assert html =~ "Referenced by Terminal states"
    assert html =~ "Needs Implementation Review"
    assert html =~ "Referenced by Human review states"
    assert html =~ "Profile implementation target states"
    assert html =~ "Allowed transition In Progress -&gt; Needs Implementation Review"
    assert html =~ "Open Workflow Settings"
    assert html =~ "Canceled"
    assert html =~ "Needs Refinement Review"
  end

  test "diagnostics rejects unsupported tracker kinds" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "not-linear", tracker_api_token: nil)

    diagnostics = Diagnostics.run()

    assert diagnostics.config.tracker_kind == "linear"
    assert diagnostics.config.endpoint == "https://api.linear.app/graphql"
    assert diagnostics.probes.api.status == :error
    assert diagnostics.probes.api.detail =~ "unsupported_tracker_kind"
    assert diagnostics.probes.teams.status == :skipped
    assert diagnostics.probes.project.status == :skipped
    assert diagnostics.probes.states.status == :skipped
    assert diagnostics.probes.candidates.status == :skipped
  end

  test "diagnostics reports api project and candidate failures independently" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiagnosticsViewer" => {:error, {:linear_api_status, 401}},
      "SymphonyLinearDiagnosticsProject" =>
        {:error,
         {:linear_api_status, 400,
          %{
            "errors" => [
              %{
                "message" => "Cannot query field \"team\" on type \"Project\". Did you mean \"teams\" or \"lead\"?",
                "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}
              }
            ]
          }}},
      candidate_result: {:error, {:linear_graphql_errors, [%{"message" => "bad query"}]}}
    })

    diagnostics = Diagnostics.run()

    assert diagnostics.probes.api.status == :error
    assert diagnostics.probes.api.detail =~ "401"
    assert diagnostics.probes.teams.status == :ok
    assert diagnostics.probes.project.status == :error
    assert diagnostics.probes.project.detail =~ "HTTP 400"
    assert diagnostics.probes.project.data.response["errors"] |> hd() |> Map.get("message") =~ "Cannot query field"
    assert diagnostics.probes.states.status == :skipped
    assert diagnostics.probes.candidates.status == :error
    assert diagnostics.issues == []
    assert Enum.any?(diagnostics.log, &(&1.step == "api" and &1.status == :error and &1.message =~ "401"))
    assert Enum.any?(diagnostics.log, &(&1.step == "candidates" and &1.status == :error))
  end

  test "diagnostics writes redacted server logs for failing probes" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiagnosticsViewer" => {:error, {:token, "secret-token-value"}}
    })

    log = capture_log(fn -> Diagnostics.run() end)

    assert log =~ "linear_diagnostics step=api status=error"
    assert log =~ "[REDACTED]"
    refute log =~ "secret-token-value"
  end

  test "linear discovery normalizes projects teams states and suggestions" do
    assert {:ok, discovery} = Discovery.fetch()

    assert discovery.viewer.name == "Ops User"
    assert [%{name: "Migration Project", slug: "migration-project"}] = discovery.projects
    assert [%{name: "Platform", key: "PLAT"}] = discovery.teams
    assert "Ready" in discovery.states
    assert "In Progress" in discovery.suggestions.active_states
    assert "Done" in discovery.suggestions.terminal_states
    assert "Needs Implementation Review" in discovery.suggestions.review_states
  end

  test "linear discovery fetches workflow states with separate per-team queries" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryViewer" => %{"data" => %{"viewer" => nil}},
      "SymphonyLinearDiscoveryTeams" => %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{"id" => "team-2", "key" => " OPS ", "name" => "Ops"},
              %{"id" => "team-1", "key" => "PLAT", "name" => "Platform"},
              %{"id" => "team-empty", "key" => "", "name" => "Empty"},
              %{"id" => "team-missing-key", "name" => "Missing Key"},
              :not_a_team
            ]
          }
        }
      },
      "SymphonyLinearDiscoveryProjects" => %{
        "data" => %{
          "projects" => %{
            "nodes" => [
              %{
                "id" => "project-2",
                "name" => "Ops Project",
                "slugId" => "ops-project",
                "url" => "https://linear.app/project/ops-project",
                "teams" => %{"nodes" => [%{"id" => "team-2", "key" => "OPS", "name" => "Ops"}, :not_a_team]}
              },
              :not_a_project
            ]
          }
        }
      },
      "SymphonyLinearDiscoveryTeamStates" => fn variables, _opts ->
        send(test_pid, {:team_states_query, variables})

        case variables do
          %{"teamKey" => "OPS"} ->
            %{
              "data" => %{
                "teams" => %{
                  "nodes" => [
                    %{
                      "id" => "team-2",
                      "key" => "OPS",
                      "states" => %{
                        "nodes" => [
                          %{"name" => " Backlog "},
                          %{"name" => "Closed"},
                          %{"name" => ""},
                          %{"name" => nil},
                          :not_a_state
                        ]
                      }
                    }
                  ]
                }
              }
            }

          %{"teamKey" => "PLAT"} ->
            %{
              "data" => %{
                "teams" => %{
                  "nodes" => [
                    %{
                      "id" => "team-1",
                      "key" => "PLAT",
                      "states" => %{"nodes" => [%{"name" => "Todo"}, %{"name" => "Review"}]}
                    }
                  ]
                }
              }
            }
        end
      end
    })

    assert {:ok, discovery} = Discovery.fetch()

    assert_receive {:team_states_query, %{"teamKey" => "OPS"}}
    assert_receive {:team_states_query, %{"teamKey" => "PLAT"}}
    refute_received {:team_states_query, %{"teamKey" => ""}}
    assert discovery.viewer == %{id: "n/a", name: "n/a", email: "n/a"}
    assert Enum.find(discovery.teams, &(&1.key == "OPS")).states == ["Backlog", "Closed"]
    assert Enum.find(discovery.teams, &(&1.key == "PLAT")).states == ["Review", "Todo"]
    assert Enum.find(discovery.projects, &(&1.slug == "ops-project")).states == ["Backlog", "Closed"]
    assert Enum.any?(discovery.projects, &(&1.name == "n/a"))
    assert "Closed" in discovery.suggestions.terminal_states
    assert "Review" in discovery.suggestions.active_states
    assert "Review" in discovery.suggestions.review_states
  end

  test "linear discovery reports graphql payload errors" do
    errors = [%{"message" => "Query too complex"}]

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryTeams" => %{"errors" => errors}
    })

    assert {:error, {:linear_graphql_errors, ^errors}} = Discovery.fetch()

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryViewer" => %{"errors" => errors}
    })

    assert {:error, {:linear_graphql_errors, ^errors}} = Discovery.fetch()

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryProjects" => %{"errors" => errors}
    })

    assert {:error, {:linear_graphql_errors, ^errors}} = Discovery.fetch()
  end

  test "linear discovery reports per-team workflow state request failures" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryTeamStates" => {:error, {:linear_api_status, 400, %{"message" => "boom"}}}
    })

    assert {:error, {:linear_api_status, 400, %{"message" => "boom"}}} = Discovery.fetch()
  end

  test "linear discovery tolerates empty payload shapes" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryTeams" => %{"data" => %{}},
      "SymphonyLinearDiscoveryProjects" => %{"data" => %{}}
    })

    assert {:ok, discovery} = Discovery.fetch()
    assert discovery.teams == []
    assert discovery.projects == []
    assert discovery.states == []
    assert discovery.suggestions == %{active_states: [], terminal_states: [], review_states: []}

    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      "SymphonyLinearDiscoveryViewer" => %{},
      "SymphonyLinearDiscoveryTeams" => %{},
      "SymphonyLinearDiscoveryProjects" => %{}
    })

    assert {:ok, discovery} = Discovery.fetch()
    assert discovery.viewer == %{}
    assert discovery.teams == []
    assert discovery.projects == []
  end

  test "linear discovery reports missing token without crashing" do
    System.delete_env("LINEAR_API_KEY")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    assert {:error, :missing_linear_api_token} = Discovery.fetch()
  end

  test "diagnostics page is linked from navigator and renders fake candidate issues" do
    Application.put_env(:symphony_elixir, :linear_diagnostics_fake, %{
      candidate_result:
        {:ok,
         [
           %Issue{
             identifier: "LIN-2",
             title: "Show issue",
             state: "In Progress",
             labels: ["ui"],
             updated_at: ~U[2026-05-01 11:00:00Z],
             url: "https://linear.app/issue/LIN-2"
           }
         ]}
    })

    start_test_endpoint()

    {:ok, _dashboard, dashboard_html} = live(build_conn(), "/")
    assert dashboard_html =~ ~s(href="/diagnostics/linear")
    assert dashboard_html =~ "Linear"

    {:ok, view, html} = live(build_conn(), "/diagnostics/linear")
    assert html =~ "Linear Diagnostics"
    refute html =~ "Fetch Linear configuration"
    refute html =~ "Linear Configuration Discovery"
    refute html =~ "No discovery data fetched yet."
    assert html =~ "Last run"
    assert html =~ "Run ID"
    assert html =~ "Diagnostics Log"
    assert html =~ "Account, Teams, and Project"
    assert html =~ "Platform"
    assert html =~ "runtime"
    assert html =~ "Project slug"
    assert html =~ "Token source"
    assert html =~ "Token fingerprint"
    assert html =~ "LIN-2"
    assert html =~ "Show issue"
    refute html =~ "Authorization"
    refute html =~ "secret"

    refreshed_html = render_click(view, "refresh_diagnostics")
    assert refreshed_html =~ "Diagnostics refreshed at"
  end

  test "diagnostics page does not expose Linear discovery controls" do
    System.delete_env("LINEAR_API_KEY")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/diagnostics/linear")
    assert html =~ "Linear Diagnostics"
    assert html =~ "Tracker Configuration"
    refute html =~ "Fetch Linear configuration"
    refute html =~ "Linear Configuration Discovery"
  end

  test "linear diagnostics route remains protected by auth" do
    Application.put_env(:symphony_elixir, :auth,
      enabled: true,
      username: "admin",
      password_hash: SymphonyElixir.Auth.hash_password("secret")
    )

    start_test_endpoint()

    conn = get(build_conn(), "/diagnostics/linear")
    assert redirected_to(conn) == "/login"
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
