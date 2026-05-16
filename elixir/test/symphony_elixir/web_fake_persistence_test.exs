defmodule SymphonyElixir.WebFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
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
                    %{"id" => "state-review", "name" => "Needs Implementation Review", "type" => "started"},
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

  test "project settings page renders fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/settings/projects")

    assert html =~ "Projects"
    assert html =~ "Linear Configuration Discovery"
    assert html =~ "Fetch Linear configuration"
    assert html =~ ~s(phx-disable-with="Fetching...")
    assert html =~ "No Linear discovery data fetched yet."
    assert html =~ "Fake Project"
    assert html =~ "fake"
    assert html =~ "git@github.com:org/repo.git"
    assert html =~ "Linear project slug"
  end

  test "project settings page fetches Linear discovery candidates" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/projects")
    assert html =~ "No Linear discovery data fetched yet."

    discovery_html = render_click(view, "fetch_linear_discovery")

    assert discovery_html =~ "Linear configuration fetched at"
    assert discovery_html =~ "Migration Project"
    assert discovery_html =~ "migration-project"
    assert discovery_html =~ "Platform"
    assert discovery_html =~ "Copy slug"
    assert discovery_html =~ "Suggested State Lists"
    assert discovery_html =~ "Needs Implementation Review"
  end

  test "project settings page shows Linear discovery errors inline" do
    System.delete_env("LINEAR_API_KEY")
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/projects")
    assert html =~ "Linear Configuration Discovery"

    error_html = render_click(view, "fetch_linear_discovery")

    assert error_html =~ "Discovery failed"
    assert error_html =~ "missing_linear_api_token"
    assert error_html =~ "Projects"
  end

  test "workflow setup-required page does not show draft validation before edits" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/workflow")

    assert html =~ "Runtime source:"
    assert html =~ "setup_required"
    assert html =~ "No active workflow is configured yet."
    assert html =~ "Workflow configuration checklist"
    assert html =~ "Workflow"
    assert html =~ "Active workflow version"
    assert html =~ "Save the draft below to create the first active workflow version."
    refute html =~ "Project configuration checklist"
    refute html =~ "Runtime configuration checklist"
    refute html =~ "Validation failed"
    refute html =~ "missing_linear_project_slug"

    edited_html =
      view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: Map.put(workflow_page_form_params(), "hook_timeout_ms", "0")
      )
      |> render_change()

    assert edited_html =~ "Validation failed"
  end

  test "workflow page does not report project-owned Linear slug errors" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    assert {:ok, _project} = FakePersistence.update_project("fake-project-id", %{linear_project_slug: nil, repository_url: nil})

    {:ok, view, html} = live(build_conn(), "/settings/workflow")

    refute html =~ "missing_linear_project_slug"

    edited_html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_change()

    refute edited_html =~ "missing_linear_project_slug"
    refute edited_html =~ "missing_project_repository_url"
    refute edited_html =~ "Validation failed"

    saved_html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert saved_html =~ "Workflow settings saved"
    refute saved_html =~ "missing_linear_project_slug"
    refute saved_html =~ "missing_project_repository_url"
  end

  test "settings configuration checklists stay on their owning pages" do
    System.delete_env("LINEAR_API_KEY")
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    assert {:ok, _project} = FakePersistence.update_project("fake-project-id", %{linear_project_slug: nil, repository_url: nil})

    {:ok, _view, workflow_html} = live(build_conn(), "/settings/workflow")

    assert workflow_html =~ "Workflow configuration checklist"
    assert workflow_html =~ "Active workflow version"
    refute workflow_html =~ "Project configuration checklist"
    refute workflow_html =~ "Runtime configuration checklist"
    refute workflow_html =~ "Linear project slug"
    refute workflow_html =~ "Repository URL"
    refute workflow_html =~ "Set LINEAR_API_KEY"
    refute workflow_html =~ "missing_linear_project_slug"
    refute workflow_html =~ "missing_project_repository_url"

    {:ok, _view, projects_html} = live(build_conn(), "/settings/projects")

    assert projects_html =~ "Project configuration checklist"
    assert projects_html =~ "Linear project slug"
    assert projects_html =~ "Repository URL"
    refute projects_html =~ "Workflow configuration checklist"
    refute projects_html =~ "Runtime configuration checklist"

    {:ok, _view, runtime_html} = live(build_conn(), "/settings/runtime")

    assert runtime_html =~ "Runtime configuration checklist"
    assert runtime_html =~ "Linear API token"
    assert runtime_html =~ "Set LINEAR_API_KEY"
    refute runtime_html =~ "Workflow configuration checklist"
    refute runtime_html =~ "Project configuration checklist"
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

  test "run detail, issue detail, and events pages render persisted observability data" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    run = %{
      id: "run-1",
      workflow_version_id: "workflow-1",
      issue_identifier: "MT-1",
      workspace_path: "/tmp/workspaces/MT-1",
      status: "failed",
      attempt: 2,
      failure_reason: "boom",
      started_at: now,
      finished_at: now
    }

    workflow_version = %{
      id: "workflow-1",
      project_id: "fake-project-id",
      version: 7,
      source: "web_workflow_settings",
      active: true,
      inserted_at: now,
      raw_workflow_md: workflow_import_raw("git@github.com:org/repo.git")
    }

    FakePersistence.put_runs([run])
    FakePersistence.put_issues([%{identifier: "MT-1", state: "In Progress", title: "Issue detail"}])
    FakePersistence.put_workflow_versions([workflow_version], workflow_version)

    FakePersistence.put_agent_turns([
      %{run_id: "run-1", turn_index: 1, status: "failed", summary: "Turn failed", started_at: now, finished_at: now}
    ])

    FakePersistence.put_events([
      %{
        run_id: "run-1",
        issue_identifier: "MT-1",
        event_type: "run.failed",
        payload: %{"api_token" => "secret", "message" => "boom"},
        occurred_at: now
      }
    ])

    {:ok, _view, run_html} = live(build_conn(), "/runs/run-1")
    assert run_html =~ "Run Detail"
    assert run_html =~ "MT-1"
    assert run_html =~ "Workflow Version"
    assert run_html =~ "Turn failed"
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

  test "workflow page saves structured draft through fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/workflow")
    assert html =~ "Draft Configuration"
    refute html =~ "Project slug"
    refute html =~ ~s(name="workflow[tracker_project_slug]")
    refute html =~ ~s(name="workflow[project_repository_url]")
    refute html =~ ~s(name="workflow[project_default_branch]")
    assert html =~ "Lifecycle Hooks"
    assert html =~ "Hook timeout ms"
    assert html =~ ~s(phx-disable-with="Saving...")
    refute html =~ "Raw workflow source"
    refute html =~ "workflow[tracker_kind]"
    refute html =~ "workflow[tracker_endpoint]"
    refute html =~ "workflow[tracker_api_key]"
    refute html =~ "API key"
    assert html =~ ~s(class="workflow-textbox workflow-textbox-compact")
    assert html =~ ~s(class="workflow-textbox workflow-textbox-medium")
    refute html =~ ~s(class="workflow-textbox workflow-textbox-prompt")
    refute html =~ ~s(name="workflow[prompt_body]")
    assert html =~ "Agents"
    refute html =~ "Profile prompt template"

    params =
      workflow_page_form_params()
      |> Map.put("workspace_root", "/tmp/structured-workspaces")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Runtime workflow refreshed"
    assert html =~ "workflow-save-toast-success"
    assert html =~ "Workflow settings saved"
    assert html =~ "Version 1 is active"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_workflow_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
               _ -> false
             end)

    assert raw =~ "/tmp/structured-workspaces"
    assert raw =~ "git@github.com:org/repo.git"
    assert raw =~ ~s(project_slug: "project")
    refute raw =~ "api_key"
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["tracker", "kind"]) == "linear"
    assert get_in(loaded_workflow.config, ["tracker", "endpoint"]) == "https://api.linear.app/graphql"
    assert {:ok, _validation} = SymphonyElixir.WorkflowValidator.validate_raw(raw)
  end

  test "agent settings page edits profile settings through the workflow draft" do
    refute Process.whereis(SymphonyElixir.Repo)
    write_workflow_file!(Workflow.workflow_file_path(), project_repository_url: "git@github.com:org/repo.git")
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/agents")
    assert html =~ "Agents"
    assert html =~ "Profile Configuration"
    assert html =~ "Base Prompt"
    assert html =~ ~s(class="workflow-form-section agent-prompt-editor")
    assert html =~ ~s(class="workflow-form-section agent-profiles-section")
    assert html =~ ~s(class="workflow-profile-field-grid")
    assert html =~ ~s(class="profile-field-group profile-field-group-prompt")
    assert html =~ ~s(class="profile-prompt-layout")
    assert html =~ ~s(class="agent-field agent-field-full")
    assert html =~ ~s(class="agent-field-label")
    assert html =~ "Identity"
    assert html =~ "Execution"
    assert html =~ "Prompt"
    assert html =~ "Updates"
    assert html =~ "Routing"
    assert html =~ ~s(class="workflow-textbox workflow-textbox-prompt")
    assert html =~ ~s(name="workflow[prompt_body]")
    assert html =~ "Profile prompt template"
    assert html =~ ~s(class="workflow-textbox workflow-textbox-profile")
    assert html =~ "Save agent settings"

    params = %{
      "prompt_body" => "Changed shared base prompt.",
      "profiles" => %{
        "implementation" => %{
          "prompt_template" => "Changed implementation profile prompt."
        }
      }
    }

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Runtime workflow refreshed"
    assert html =~ "Agent settings saved"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_agent_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_agent_settings"} -> true
               _ -> false
             end)

    assert raw =~ "Changed implementation profile prompt."
    assert raw =~ "Changed shared base prompt."
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert loaded_workflow.prompt == "Changed shared base prompt."
    assert get_in(loaded_workflow.config, ["profiles", "implementation", "prompt", "template"]) == "Changed implementation profile prompt."
  end

  test "settings tabs render only the active settings surface" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, projects_html} = live(build_conn(), "/settings")
    assert projects_html =~ "Projects"
    assert projects_html =~ "Add Project"
    refute projects_html =~ "Draft Configuration"
    refute projects_html =~ "Profile Configuration"
    refute projects_html =~ "Execution mode:"

    {:ok, _view, workflow_html} = live(build_conn(), "/settings/workflow")
    assert workflow_html =~ "Draft Configuration"
    assert workflow_html =~ "Version History"
    refute workflow_html =~ "Add Project"
    refute workflow_html =~ "Profile Configuration"
    refute workflow_html =~ "Execution mode:"

    {:ok, _view, agents_html} = live(build_conn(), "/settings/agents")
    assert agents_html =~ "Profile Configuration"
    assert agents_html =~ "Base Prompt"
    assert agents_html =~ "Version History"
    refute agents_html =~ "Draft Configuration"
    refute agents_html =~ "Execution mode:"

    {:ok, _view, runtime_html} = live(build_conn(), "/settings/runtime")
    assert runtime_html =~ "Execution mode:"
    refute runtime_html =~ "Draft Configuration"
    refute runtime_html =~ "Profile Configuration"
    refute runtime_html =~ "Version History"
  end

  test "project settings page creates and updates projects" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/projects")

    html =
      view
      |> form(".project-create-form",
        project: %{
          "name" => "Second Project",
          "slug" => "second",
          "linear_project_slug" => "linear-second",
          "repository_url" => "git@github.com:org/second.git",
          "default_branch" => "develop",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Project settings saved"
    assert html =~ "Second Project"
    assert html =~ "git@github.com:org/second.git"

    assert Enum.any?(FakePersistence.calls(), fn
             {:create_project, attrs} -> attrs.name == "Second Project" and attrs.repository_url == "git@github.com:org/second.git"
             _ -> false
           end)

    html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: %{
          "id" => "fake-project-id",
          "name" => "Renamed Project",
          "slug" => "fake",
          "linear_project_slug" => "renamed-linear",
          "repository_url" => "git@github.com:org/renamed.git",
          "default_branch" => "main",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Renamed Project"
    assert html =~ "git@github.com:org/renamed.git"
  end

  test "settings pages show separate version histories" do
    refute Process.whereis(SymphonyElixir.Repo)

    now = DateTime.utc_now()

    workflow_version = workflow_version("workflow-version", 3, "web_workflow_settings", workflow_import_raw("git@github.com:org/workflow.git"), now)
    manual_version = workflow_version("manual-version", 2, "manual_import", workflow_import_raw("git@github.com:org/manual.git"), now)
    agent_version = workflow_version("agent-version", 4, "web_agent_settings", agent_history_raw("git@github.com:org/agent.git"), now)

    FakePersistence.put_workflow_versions([agent_version, workflow_version, manual_version], workflow_version)
    start_test_endpoint()

    {:ok, _view, workflow_html} = live(build_conn(), "/settings/workflow")
    assert workflow_html =~ "web_workflow_settings"
    refute workflow_html =~ "manual_import"
    assert workflow_html =~ "Restore workflow settings"
    refute workflow_html =~ "web_agent_settings"
    refute workflow_html =~ "Restore agent settings"

    {:ok, _view, agents_html} = live(build_conn(), "/settings/agents")
    assert agents_html =~ "web_agent_settings"
    assert agents_html =~ "Restore agent settings"
    refute agents_html =~ "web_workflow_settings"
    refute agents_html =~ "manual_import"
    refute agents_html =~ "Restore workflow settings"
  end

  test "agent settings history restore only restores prompt and profiles" do
    refute Process.whereis(SymphonyElixir.Repo)

    now = DateTime.utc_now()
    current = workflow_version("current-version", 10, "web_workflow_settings", agent_history_raw("git@github.com:org/current.git"), now)
    history = workflow_version("agent-history", 9, "web_agent_settings", agent_history_raw("git@github.com:org/agent-history.git"), now)

    FakePersistence.put_workflow_versions([current, history], current)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/agents")
    assert html =~ "Restore agent settings"

    html = render_click(view, "restore_settings_version", %{"id" => "agent-history"})
    assert html =~ "Agent settings restored"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_agent_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_agent_settings"} -> true
               _ -> false
             end)

    assert raw =~ "git@github.com:org/repo.git"
    refute raw =~ "git@github.com:org/current.git"
    refute raw =~ "git@github.com:org/agent-history.git"
    assert raw =~ "Agent history prompt."
    assert raw =~ "History implementation prompt."
  end

  test "workflow settings history restore keeps current prompt and profiles" do
    refute Process.whereis(SymphonyElixir.Repo)

    now = DateTime.utc_now()
    current = workflow_version("current-version", 10, "web_agent_settings", agent_history_raw("git@github.com:org/current.git"), now)
    history = workflow_version("workflow-history", 9, "web_workflow_settings", workflow_import_raw("git@github.com:org/workflow-history.git"), now)

    FakePersistence.put_workflow_versions([current, history], current)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/workflow")
    assert html =~ "Restore workflow settings"

    html = render_click(view, "restore_settings_version", %{"id" => "workflow-history"})
    assert html =~ "Workflow settings restored"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_workflow_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
               _ -> false
             end)

    assert raw =~ "git@github.com:org/repo.git"
    refute raw =~ "git@github.com:org/workflow-history.git"
    assert raw =~ "Agent history prompt."
    assert raw =~ "History implementation prompt."
    refute raw =~ "Imported workflow prompt."
    refute raw =~ "Implement the task."
  end

  test "old workflow and agent settings routes are removed" do
    start_test_endpoint()

    assert build_conn() |> get("/workflows") |> response(404) =~ "Route not found"
    assert build_conn() |> get("/agent-settings") |> response(404) =~ "Route not found"
    assert build_conn() |> get("/projects") |> response(404) =~ "Route not found"
  end

  test "workflow page uses an explicit add button for allowed transitions" do
    refute Process.whereis(SymphonyElixir.Repo)
    write_workflow_file!(Workflow.workflow_file_path(), workflow_policy: workflow_policy_without_transitions())
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/workflow")

    assert html =~ ~s(aria-label="Add transition")
    refute html =~ ~s(name="workflow[allowed_transitions][0][from]")

    html =
      view
      |> element("button[phx-click='add_workflow_transition']")
      |> render_click()

    assert html =~ ~s(name="workflow[allowed_transitions][0][from]")
    assert html =~ ~s(name="workflow[allowed_transitions][0][to]")
  end

  test "workflow form saves and clears lifecycle hooks" do
    draft =
      SymphonyElixir.WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY",
            "project_slug" => "project",
            "active_states" => ["Ready"],
            "terminal_states" => ["Done"]
          },
          "polling" => %{"interval_ms" => 30_000},
          "project" => %{"repository_url" => "git@github.com:org/repo.git"},
          "hooks" => %{
            "timeout_ms" => 60_000,
            "after_create" => "echo stale",
            "before_run" => "echo before"
          }
        },
        prompt: "Hook prompt"
      })

    assert draft["hook_after_create"] == "echo stale"
    assert draft["hook_before_run"] == "echo before"

    edited =
      draft
      |> Map.put("hook_after_create", "")
      |> Map.put("hook_before_run", "echo edited")
      |> Map.put("hook_after_run", "echo after")
      |> Map.put("hook_before_remove", "echo remove")
      |> Map.put("hook_timeout_ms", "45000")

    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)

    hooks = get_in(loaded_workflow.config, ["hooks"])
    refute Map.has_key?(hooks, "after_create")
    assert hooks["before_run"] == "echo edited"
    assert hooks["after_run"] == "echo after"
    assert hooks["before_remove"] == "echo remove"
    assert hooks["timeout_ms"] == 45_000
  end

  test "workflow form saves editable allowed transitions" do
    draft =
      SymphonyElixir.WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY",
            "project_slug" => "project",
            "active_states" => ["Ready", "In Progress", "Ready to Merge"],
            "terminal_states" => ["Done"]
          },
          "project" => %{"repository_url" => "git@github.com:org/repo.git"},
          "workflow" => %{
            "states" => %{
              "Ready" => %{"profile" => "implementation"},
              "In Progress" => %{"profile" => "implementation"},
              "Ready to Merge" => %{"profile" => "merge"}
            },
            "human_review_states" => ["Needs Refinement Review", "In Review"],
            "allowed_transitions" => [
              %{"from" => "Ready", "to" => "In Progress", "actor" => "codex", "profile" => "implementation"}
            ]
          },
          "profiles" => %{
            "implementation" => %{
              "name" => "Implementation",
              "executor" => %{"type" => "codex_agent"},
              "prompt" => %{"mode" => "extend", "template" => "Implement it"},
              "allowed_updates" => %{"comment" => true, "result" => true, "target_states" => ["In Progress", "In Review"]}
            },
            "merge" => %{
              "name" => "Merge",
              "executor" => %{"type" => "codex_agent"},
              "prompt" => %{"mode" => "extend", "template" => "Merge it"},
              "allowed_updates" => %{"comment" => true, "result" => true, "target_states" => ["Done"]}
            }
          }
        },
        prompt: "Transition prompt"
      })

    edited =
      put_in(draft, ["allowed_transitions"], %{
        "0" => %{"from" => "Ready", "to" => "In Progress", "actor" => "codex", "profile" => "implementation"},
        "1" => %{"from" => "In Progress", "to" => "In Review", "actor" => "codex", "profile" => "implementation"},
        "2" => %{"from" => "", "to" => "", "actor" => "", "profile" => ""}
      })

    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)

    assert get_in(loaded_workflow.config, ["workflow", "allowed_transitions"]) == [
             %{"actor" => "codex", "from" => "Ready", "profile" => "implementation", "to" => "In Progress"},
             %{"actor" => "codex", "from" => "In Progress", "profile" => "implementation", "to" => "In Review"}
           ]

    assert {:ok, _validation} = SymphonyElixir.WorkflowValidator.validate_raw(raw)
  end

  test "workflow form rejects invalid lifecycle hook timeout" do
    draft =
      workflow_form_params()
      |> Map.put("_base_config", %{})
      |> Map.put("hook_timeout_ms", "0")

    assert {:error, "Hook timeout must be a positive integer"} =
             SymphonyElixir.WorkflowForm.to_raw(draft)
  end

  test "workflow page rejects invalid structured draft before import" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/workflow")

    params =
      workflow_page_form_params()
      |> Map.put("polling_interval_ms", "bad")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Validation failed"
    assert html =~ "workflow-save-toast-error"
    assert html =~ "Workflow settings save failed"
    assert html =~ "Polling interval must be a positive integer"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)
  end

  test "workflow page shows popup feedback when save persistence fails" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    FakePersistence.fail_next_import_workflow!(:database_unavailable)

    {:ok, view, _html} = live(build_conn(), "/settings/workflow")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert html =~ "workflow-save-toast-error"
    assert html =~ "Workflow settings save failed"
    assert html =~ "database_unavailable"
    refute html =~ "workflow-save-toast-success"

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
             _ -> false
           end)
  end

  test "workflow page refuses to restore an invalid historical workflow version" do
    refute Process.whereis(SymphonyElixir.Repo)

    invalid = %{
      id: "invalid-version",
      project_id: "fake-project-id",
      version: 2,
      source: "web_workflow_settings",
      active: false,
      inserted_at: DateTime.utc_now(),
      raw_workflow_md: "---\nworkflow:\n  allowed_transitions:\n    - {from: Ready, to: Done, actor: robot}\n---\nPrompt\n"
    }

    FakePersistence.put_workflow_versions([invalid])
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/workflow")
    html = render_click(view, "restore_settings_version", %{"id" => "invalid-version"})

    assert html =~ "Validation failed"
    assert html =~ "allowed_transitions.actor"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, %{id: "fake-project-id"}, _raw, _source} -> true
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

  defp workflow_form_params do
    %{
      "tracker_project_slug" => "project",
      "tracker_assignee" => "",
      "active_states" => "Refining\nReady\nIn Progress\nReady to Merge\nMerging",
      "terminal_states" => "Canceled\nCancelled\nDuplicate\nDone",
      "polling_interval_ms" => "30000",
      "project_repository_url" => "git@github.com:org/repo.git",
      "project_default_branch" => "main",
      "project_checkout_depth" => "1",
      "project_setup_commands" => "mix deps.get",
      "project_cleanup_commands" => "",
      "workspace_root" => "/tmp/symphony-workspaces",
      "agent_max_concurrent_agents" => "1",
      "agent_max_turns" => "20",
      "codex_command" => "codex app-server",
      "codex_thread_sandbox" => "workspace-write",
      "hook_after_create" => "",
      "hook_before_run" => "",
      "hook_after_run" => "",
      "hook_before_remove" => "",
      "hook_timeout_ms" => "60000",
      "prompt_body" => "You are an agent for this repository."
    }
  end

  defp workflow_page_form_params do
    workflow_form_params()
    |> Map.delete("prompt_body")
    |> Map.delete("tracker_project_slug")
    |> Map.delete("project_repository_url")
    |> Map.delete("project_default_branch")
  end

  defp workflow_version(id, version, source, raw, inserted_at) do
    %{
      id: id,
      project_id: "fake-project-id",
      version: version,
      source: source,
      active: false,
      inserted_at: inserted_at,
      raw_workflow_md: raw
    }
  end

  defp workflow_policy_without_transitions do
    %{
      "states" => %{
        "Ready" => %{"profile" => "implementation"},
        "In Progress" => %{"profile" => "implementation"}
      },
      "human_review_states" => ["In Review"],
      "allowed_transitions" => []
    }
  end

  defp workflow_import_raw(repository_url) do
    """
    ---
    tracker:
      kind: linear
      endpoint: "https://api.linear.app/graphql"
      project_slug: "project"
      active_states: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"]
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
      max_concurrent_agents: 1
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
        Ready to Merge:
          profile: merge
        Merging:
          profile: merge
      human_review_states: ["Needs Refinement Review", "Needs Implementation Review"]
      allowed_transitions:
        - {from: Ready, to: In Progress, actor: codex, profile: implementation}
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
        allowed_updates: {description: false, comment: true, result: true, target_states: ["In Progress", "Needs Implementation Review"]}
      merge:
        name: "Merge"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Merge the task."}
        allowed_updates: {description: false, comment: true, result: true, target_states: ["Merging", "Done"]}
    ---

    Imported workflow prompt.
    """
  end

  defp agent_history_raw(repository_url) do
    repository_url
    |> workflow_import_raw()
    |> String.replace("Imported workflow prompt.", "Agent history prompt.")
    |> String.replace("Implement the task.", "History implementation prompt.")
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
