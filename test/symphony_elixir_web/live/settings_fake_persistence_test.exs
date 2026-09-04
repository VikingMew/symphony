defmodule SymphonyElixirWeb.Live.SettingsFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.WorkflowForm
  alias SymphonyElixir.WorkflowStore

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
                    %{"id" => "state-blocked", "name" => "Blocked", "type" => "started"},
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

  defmodule NoDefaultPersistence do
    @moduledoc false

    def default_project, do: {:error, :not_found}

    defdelegate list_projects(), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate current_workflow(project), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate workflow_to_loaded(version), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate export_workflow(version), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_runs_page(opts), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_events(opts), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_tasks(opts), to: SymphonyElixir.TestSupport.FakePersistence
    defdelegate list_task_leases(opts), to: SymphonyElixir.TestSupport.FakePersistence
  end

  defmodule BusyOperatorOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :snapshot)}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

    def handle_call({:request_operator_task, kind, project_id}, _from, snapshot) do
      failure_reason = "operator_task_busy: #{kind} run is already in progress"

      reply = %{
        accepted: false,
        kind: to_string(kind),
        project_id: project_id,
        status: "failed",
        run_id: "operator-#{kind}-active",
        requested_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        queued_at: nil,
        started_at: nil,
        finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        failure_reason: failure_reason,
        summary: %{created: 0, skipped: 0, failed: 1, issues: [], error: failure_reason}
      }

      {:reply, reply, snapshot}
    end
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
    :ok = WorkflowStore.force_reload()

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

  test "dashboard shows a friendly flash when a nap is already running" do
    refute Process.whereis(SymphonyElixir.Repo)
    orchestrator_name = Module.concat(__MODULE__, :BusyDashboardOperator)

    start_supervised!({BusyOperatorOrchestrator, name: orchestrator_name, snapshot: dashboard_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view
      |> form("#request-nap-form", %{"project_id" => "fake-project-id"})
      |> render_submit()

    assert html =~ "Take a nap failed: a nap run is already in progress for this project"
    refute html =~ "operator_task_busy"
  end

  test "settings Linear discovery is shared across project and workflow tabs" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/projects")
    assert html =~ "No Linear discovery data fetched yet."

    projects_html = render_click(view, "fetch_linear_discovery")

    assert projects_html =~ "Fetched at"
    assert projects_html =~ "Refresh Linear configuration"
    assert projects_html =~ "Linear Project Candidates"
    assert projects_html =~ "Migration Project"
    assert projects_html =~ "migration-project"
    assert projects_html =~ "Platform"
    assert projects_html =~ "Copy slug"
    refute projects_html =~ "Linear Workflow State Candidates"
    refute projects_html =~ "Suggested State Lists"

    workflow_html =
      view
      |> element(~s(a[href="/settings/workflow"]), "Workflow")
      |> render_click()

    assert workflow_html =~ "Fetched at"
    assert workflow_html =~ "Refresh Linear configuration"
    assert workflow_html =~ "Linear Workflow State Candidates"
    assert workflow_html =~ "Suggested State Lists"
    assert workflow_html =~ "Ready to Merge"
    refute workflow_html =~ "Linear Project Candidates"

    assert length(Regex.scan(~r/Refresh Linear configuration/, workflow_html)) == 1

    projects_html =
      view
      |> element(~s(a[href="/settings/projects"]), "Projects")
      |> render_click()

    assert projects_html =~ "Fetched at"
    assert projects_html =~ "Linear Project Candidates"
    assert projects_html =~ "migration-project"
    refute projects_html =~ "Linear Workflow State Candidates"
  end

  test "workflow settings explains Linear state mismatches after discovery" do
    Application.put_env(:symphony_elixir, :linear_discovery_fake, %{
      "SymphonyLinearDiscoveryTeamStates" => %{
        "data" => %{
          "teams" => %{
            "nodes" => [
              %{
                "id" => "team-1",
                "key" => "PLAT",
                "states" => %{
                  "nodes" => [
                    %{"name" => "Refining"},
                    %{"name" => "Needs Refinement Review"},
                    %{"name" => "Ready"},
                    %{"name" => "In Progress"},
                    %{"name" => "Done"},
                    %{"name" => "Canceled"},
                    %{"name" => "Duplicate"}
                  ]
                }
              }
            ]
          }
        }
      }
    })

    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/workflow")
    refute html =~ "Linear state check"

    html = render_click(view, "fetch_linear_discovery")

    assert html =~ "Linear state check"
    assert html =~ "Settings are structurally valid"
    assert html =~ "Cancelled"
    assert html =~ "Referenced by Terminal states"
    assert html =~ "Ready to Merge"
    assert html =~ "Referenced by Human review states"
    assert html =~ "Profile implementation target states"
    assert html =~ "Allowed transition In Progress -&gt; Ready to Merge"
    assert html =~ "Needs Refinement Review"
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
    assert html =~ "No workflow is configured yet."
    assert html =~ "Workflow configuration checklist"
    assert html =~ "Workflow"
    assert html =~ "Current workflow"
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

    assert edited_html =~ "Field errors"
    assert edited_html =~ "Hook timeout must be a positive integer"
  end

  test "agent settings setup-required page does not expose setup prompt as base prompt" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/settings/agents")

    assert html =~ "Base Prompt"
    assert html =~ ~s(name="workflow[prompt_body]")
    refute html =~ "Create a workflow from the Web UI to start running agents."
  end

  test "settings import package populates structured agent draft before save" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _agents_view, agents_html} = live(build_conn(), "/settings/agents")
    refute agents_html =~ "Import Settings Package"
    refute agents_html =~ ~s(name="import[yaml]")

    {:ok, view, html} = live(build_conn(), "/settings/import")
    assert html =~ "Import Settings Package"
    refute html =~ ~s(name="import[kind]")
    assert html =~ ~s(name="import[yaml]")
    assert html =~ ">Review import</button>"

    workflow_staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{
          "yaml" => split_workflow_yaml()
        }
      )
      |> render_submit()

    assert workflow_staged_html =~ "workflow.yml staged"
    assert workflow_staged_html =~ "Detected"
    assert workflow_staged_html =~ "workflow.yml"

    workflow_imported_html = render_click(view, "confirm_settings_import")
    assert workflow_imported_html =~ "Draft Configuration"

    render_patch(view, "/settings/import")

    profiles_staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{
          "yaml" => split_profiles_yaml()
        }
      )
      |> render_submit()

    assert profiles_staged_html =~ "profiles.yml staged"
    profiles_imported_html = render_click(view, "confirm_settings_import")
    assert profiles_imported_html =~ "Imported base prompt."

    render_patch(view, "/settings/workflow")

    saved_html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert saved_html =~ "Workflow settings saved"

    {:ok, _agents_view, imported_agents_html} = live(build_conn(), "/settings/agents")
    assert imported_agents_html =~ "Imported base prompt."
    assert imported_agents_html =~ "Imported implementation prompt."
    assert imported_agents_html =~ "Save agent settings"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_workflow_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
               _ -> false
             end)

    assert raw =~ "Imported base prompt."
    assert raw =~ "Imported implementation prompt."
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert loaded_workflow.prompt == "Imported base prompt."
    assert get_in(loaded_workflow.config, ["profiles", "implementation", "prompt", "template"]) == "Imported implementation prompt."
  end

  test "settings import profiles package populates unsaved agent draft" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/import")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{
          "yaml" => split_profiles_yaml()
        }
      )
      |> render_submit()

    assert staged_html =~ "profiles.yml staged"
    imported_html = render_click(view, "confirm_settings_import")
    assert imported_html =~ "Imported base prompt."

    agents_draft_html = render_patch(view, "/settings/agents")
    assert agents_draft_html =~ "Imported base prompt."
    assert agents_draft_html =~ "Imported implementation prompt."
  end

  test "settings import accepts uploaded package files and can cancel staged changes" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/settings/import")
    assert html =~ "Upload file"

    upload =
      file_input(view, "form[phx-submit='stage_settings_import']", :settings_package, [
        %{
          name: "profiles.yml",
          content: split_profiles_yaml(),
          type: "text/yaml"
        }
      ])

    render_upload(upload, "profiles.yml")

    html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => ""})
      |> render_submit()

    assert html =~ "profiles.yml staged"
    assert render_click(view, "cancel_settings_import") =~ "Import cancelled"

    agents_html = render_patch(view, "/settings/agents")
    refute agents_html =~ "Imported base prompt."
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
    assert workflow_html =~ "Current workflow"
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
    assert projects_html =~ "settings-check-invalid"
    assert projects_html =~ "settings-check-title-invalid"
    refute projects_html =~ "Workflow configuration checklist"
    refute projects_html =~ "Runtime configuration checklist"

    {:ok, _view, runtime_html} = live(build_conn(), "/settings/runtime")

    assert runtime_html =~ "Runtime configuration checklist"
    assert runtime_html =~ "Linear API token"
    assert runtime_html =~ "Set LINEAR_API_KEY"
    refute runtime_html =~ "Workflow configuration checklist"
    refute runtime_html =~ "Project configuration checklist"
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
    assert html =~ "Initialize timeout ms"
    assert html =~ "Hook timeout ms"
    assert html =~ "Approval policy"
    assert html =~ ~s(name="workflow[codex_approval_policy]")
    assert html =~ "Turn sandbox"
    assert html =~ ~s(name="workflow[codex_turn_sandbox_preset]")
    assert html =~ ~s(name="workflow[codex_turn_sandbox_json]")
    assert html =~ ~s(value="never")
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
    assert html =~ ~s(<option value="symphony" selected="">symphony</option>)

    params =
      workflow_page_form_params()
      |> Map.put("workspace_root", "/tmp/structured-workspaces")
      |> Map.put("codex_turn_sandbox_preset", "danger_full_access")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Runtime workflow refreshed"
    assert html =~ "workflow-save-toast-success"
    assert html =~ "Workflow settings saved"
    assert html =~ "Current workflow updated"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_workflow_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
               _ -> false
             end)

    assert raw =~ "/tmp/structured-workspaces"
    assert raw =~ "git@github.com:org/repo.git"
    assert raw =~ ~s(project_slug: "project")
    assert raw =~ ~s(approval_policy: "never")
    assert raw =~ ~s(type: "dangerFullAccess")
    refute raw =~ "api_key"
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["tracker", "kind"]) == "linear"
    assert get_in(loaded_workflow.config, ["tracker", "endpoint"]) == "https://api.linear.app/graphql"
    assert get_in(loaded_workflow.config, ["codex", "turn_sandbox_policy"]) == %{"type" => "dangerFullAccess"}
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
    assert html =~ "Base prompt"
    assert html =~ "Profile templates"
    assert html =~ "Prompt warnings"
    assert html =~ "template chars"
    assert html =~ "effective chars"
    assert html =~ "Base Prompt used"
    assert html =~ "Preview effective prompt"
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
    refute workflow_html =~ "Version History"
    refute workflow_html =~ "Add Project"
    refute workflow_html =~ "Profile Configuration"
    refute workflow_html =~ "Execution mode:"

    {:ok, _view, agents_html} = live(build_conn(), "/settings/agents")
    assert agents_html =~ "Profile Configuration"
    assert agents_html =~ "Base Prompt"
    refute agents_html =~ "Version History"
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
          "checkout_depth" => "3",
          "source_strategy" => "worktree",
          "worktree_fetch" => "true",
          "worktree_cleanup" => "false",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Project settings saved"
    assert html =~ "Second Project"
    assert html =~ "git@github.com:org/second.git"

    assert Enum.any?(FakePersistence.calls(), fn
             {:create_project, attrs} ->
               attrs.name == "Second Project" and attrs.repository_url == "git@github.com:org/second.git" and
                 attrs.checkout_depth == 3 and attrs.source_strategy == "worktree" and
                 attrs.worktree_fetch == true and
                 attrs.worktree_cleanup == false

             _ ->
               false
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
          "checkout_depth" => "1",
          "source_strategy" => "clone",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Renamed Project"
    assert html =~ "git@github.com:org/renamed.git"
  end

  test "project settings save refreshes runtime project configuration" do
    refute Process.whereis(SymphonyElixir.Repo)

    raw = workflow_raw!(workflow_form_params())
    active = workflow_record("current-workflow", "web_workflow_settings", raw, DateTime.utc_now())
    FakePersistence.put_workflow(active)

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/projects")

    _html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: %{
          "id" => "fake-project-id",
          "name" => "Fake Project",
          "slug" => "fake",
          "linear_project_slug" => "runtime-linear",
          "repository_url" => "git@github.com:org/runtime.git",
          "default_branch" => "master",
          "checkout_depth" => "1",
          "source_strategy" => "worktree",
          "worktree_fetch" => "true",
          "worktree_cleanup" => "true",
          "description" => "",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert {:ok, %{workflow: workflow}} = WorkflowStore.current_with_source()

    assert get_in(workflow.config, ["tracker", "project_slug"]) == "runtime-linear"
    assert get_in(workflow.config, ["project", "repository_url"]) == "git@github.com:org/runtime.git"
    assert get_in(workflow.config, ["project", "default_branch"]) == "master"
    assert get_in(workflow.config, ["project", "source_strategy"]) == "worktree"
    refute Map.has_key?(get_in(workflow.config, ["project"]), "worktree_base_path")
    refute Map.has_key?(get_in(workflow.config, ["project"]), "worktree_root")
  end

  test "settings save controls show saving feedback and saved notices" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, project_view, project_html} = live(build_conn(), "/settings/projects")
    assert project_html =~ ~s(phx-disable-with="Saving...")
    assert project_html =~ "Save project"
    assert project_html =~ "Add project"

    project_saved_html =
      project_view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: %{
          "id" => "fake-project-id",
          "name" => "Saved Project",
          "slug" => "fake",
          "linear_project_slug" => "saved-linear",
          "repository_url" => "git@github.com:org/saved.git",
          "default_branch" => "main",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert project_saved_html =~ "workflow-save-toast-success"
    assert project_saved_html =~ "Project settings saved"

    {:ok, workflow_view, workflow_html} = live(build_conn(), "/settings/workflow")
    assert workflow_html =~ ~s(phx-disable-with="Saving...")
    assert workflow_html =~ "novalidate"
    assert workflow_html =~ "Save workflow"
    refute workflow_html =~ ~s(disabled="disabled")

    workflow_saved_html =
      workflow_view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert workflow_saved_html =~ "workflow-save-toast-success"
    assert workflow_saved_html =~ "Workflow settings saved"
    refute workflow_saved_html =~ "Validation failed"

    {:ok, agent_view, agent_html} = live(build_conn(), "/settings/agents")
    assert agent_html =~ ~s(phx-disable-with="Saving...")
    assert agent_html =~ "novalidate"
    assert agent_html =~ "Save agent settings"
    refute agent_html =~ ~s(disabled="disabled")

    agent_saved_html =
      agent_view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: %{
          "prompt_body" => "Saved shared base prompt.",
          "profiles" => %{
            "implementation" => %{
              "prompt_template" => "Saved implementation profile prompt."
            }
          }
        }
      )
      |> render_submit()

    assert agent_saved_html =~ "workflow-save-toast-success"
    assert agent_saved_html =~ "Agent settings saved"
    refute agent_saved_html =~ "Validation failed"

    {:ok, _runtime_view, runtime_html} = live(build_conn(), "/settings/runtime")
    refute runtime_html =~ "Save workflow"
    refute runtime_html =~ "Save agent settings"
    refute runtime_html =~ "Save project"
  end

  test "settings no-op saves show unchanged notices without persistence" do
    refute Process.whereis(SymphonyElixir.Repo)

    raw = workflow_raw!(workflow_form_params())
    active = workflow_record("current-workflow", "web_workflow_settings", raw, DateTime.utc_now())
    FakePersistence.put_workflow(active)

    start_test_endpoint()

    {:ok, workflow_view, _workflow_html} = live(build_conn(), "/settings/workflow")

    workflow_noop_html =
      workflow_view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert workflow_noop_html =~ "workflow-save-toast-info"
    assert workflow_noop_html =~ "Workflow settings already up to date"
    assert workflow_noop_html =~ "No changes to save"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)

    {:ok, agent_view, _agent_html} = live(build_conn(), "/settings/agents")

    agent_noop_html =
      agent_view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: %{"prompt_body" => "You are an agent for this repository."}
      )
      |> render_submit()

    assert agent_noop_html =~ "workflow-save-toast-info"
    assert agent_noop_html =~ "Agent settings already up to date"
    assert agent_noop_html =~ "No changes to save"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)

    {:ok, project_view, _project_html} = live(build_conn(), "/settings/projects")

    project_noop_html =
      project_view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: %{
          "id" => "fake-project-id",
          "name" => "Fake Project",
          "slug" => "fake",
          "linear_project_slug" => "project",
          "repository_url" => "git@github.com:org/repo.git",
          "default_branch" => "main",
          "checkout_depth" => "1",
          "source_strategy" => "clone",
          "worktree_fetch" => "true",
          "worktree_cleanup" => "true",
          "description" => "",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert project_noop_html =~ "workflow-save-toast-info"
    assert project_noop_html =~ "Project settings already up to date"
    assert project_noop_html =~ "No changes to save"

    refute Enum.any?(FakePersistence.calls(), fn
             {:update_project, "fake-project-id", _attrs} -> true
             _ -> false
           end)
  end

  test "settings no-op save keeps semantic check messages without creating another version" do
    refute Process.whereis(SymphonyElixir.Repo)

    invalid_params =
      workflow_form_params()
      |> Map.put("allowed_transitions", %{
        "0" => %{"from" => "In Progress", "to" => "Unknown Review", "actor" => "codex", "profile" => "implementation"}
      })

    raw = workflow_raw!(invalid_params)
    active = workflow_record("current-invalid-workflow", "web_workflow_settings", raw, DateTime.utc_now())
    FakePersistence.put_workflow(active)

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/workflow")

    params =
      workflow_page_form_params()
      |> Map.put("allowed_transitions", %{
        "0" => %{"from" => "In Progress", "to" => "Unknown Review", "actor" => "codex", "profile" => "implementation"}
      })

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "workflow-save-toast-info"
    assert html =~ "Workflow settings already up to date"
    assert html =~ "Configuration check failed"
    assert html =~ "Allowed transition 1"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)
  end

  test "settings pages do not expose workflow history or restore controls" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    for path <- ["/settings/workflow", "/settings/agents"] do
      {:ok, _view, html} = live(build_conn(), path)
      refute html =~ "Version History"
      refute html =~ "Restore workflow settings"
      refute html =~ "Restore agent settings"
      refute html =~ "restore_settings_version"
    end
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
          "workspace" => %{"initialize_timeout_ms" => 60_000},
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
      |> Map.put("initialize_timeout_ms", "90000")
      |> Map.put("hook_timeout_ms", "45000")

    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)

    hooks = get_in(loaded_workflow.config, ["hooks"])
    workspace = get_in(loaded_workflow.config, ["workspace"])
    assert workspace["initialize_timeout_ms"] == 90_000
    refute Map.has_key?(hooks, "after_create")
    assert hooks["before_run"] == "echo edited"
    assert hooks["after_run"] == "echo after"
    assert hooks["before_remove"] == "echo remove"
    assert hooks["timeout_ms"] == 45_000
  end

  test "workflow form saves editable allowed transitions" do
    workflow_policy = Schema.default_workflow_policy()

    draft =
      SymphonyElixir.WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY",
            "project_slug" => "project",
            "active_states" => ["Todo", "Ready", "In Progress"],
            "terminal_states" => ["Canceled", "Cancelled", "Duplicate", "Done"]
          },
          "project" => %{"repository_url" => "git@github.com:org/repo.git"},
          "workflow" => workflow_policy,
          "profiles" => %{
            "refinement" => %{
              "name" => "Refinement",
              "executor" => %{"type" => "codex_agent"},
              "prompt" => %{"mode" => "extend", "template" => "Refine it"},
              "allowed_updates" => %{"comment" => true, "target_states" => ["Needs Refinement Review"]}
            },
            "implementation" => %{
              "name" => "Implementation",
              "executor" => %{"type" => "codex_agent"},
              "prompt" => %{"mode" => "extend", "template" => "Implement it"},
              "allowed_updates" => %{"comment" => true, "result" => true, "target_states" => ["In Progress", "Ready to Merge"]}
            }
          }
        },
        prompt: "Transition prompt"
      })

    edited =
      put_in(draft, ["allowed_transitions"], %{
        "0" => %{"from" => "", "to" => "", "actor" => "", "profile" => ""}
      })

    edited =
      workflow_policy["allowed_transitions"]
      |> Enum.with_index(1)
      |> Enum.reduce(edited, fn {transition, index}, form ->
        put_in(form, ["allowed_transitions", Integer.to_string(index)], transition)
      end)

    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)

    assert get_in(loaded_workflow.config, ["workflow", "allowed_transitions"]) ==
             workflow_policy["allowed_transitions"]

    assert {:ok, _validation} = SymphonyElixir.WorkflowValidator.validate_raw(raw)
  end

  test "workflow form preserves and edits codex turn sandbox policy" do
    draft =
      WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "project_slug" => "project",
            "active_states" => ["Ready"],
            "terminal_states" => ["Done"]
          },
          "project" => %{"repository_url" => "git@github.com:org/repo.git"},
          "codex" => %{
            "command" => "codex app-server",
            "approval_policy" => "never",
            "thread_sandbox" => "workspace-write",
            "turn_sandbox_policy" => %{"type" => "workspaceWrite", "networkAccess" => true}
          }
        },
        prompt: "Sandbox prompt"
      })

    assert draft["codex_turn_sandbox_preset"] == "workspace_write_network"

    assert {:ok, raw} = WorkflowForm.to_raw(draft)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["codex", "turn_sandbox_policy", "networkAccess"]) == true

    edited = Map.put(draft, "codex_turn_sandbox_preset", "danger_full_access")
    assert {:ok, raw} = WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["codex", "turn_sandbox_policy"]) == %{"type" => "dangerFullAccess"}
  end

  test "workflow form validates custom codex turn sandbox JSON" do
    draft =
      workflow_form_params()
      |> Map.put("_base_config", %{})
      |> Map.put("codex_turn_sandbox_preset", "custom")
      |> Map.put("codex_turn_sandbox_json", "not json")

    assert {:error, "Turn sandbox custom JSON is invalid"} = WorkflowForm.to_raw(draft)

    assert WorkflowForm.field_errors(draft) == %{
             "codex_turn_sandbox_json" => "Turn sandbox custom JSON is invalid"
           }
  end

  test "workflow form rejects invalid lifecycle hook timeout" do
    draft =
      workflow_form_params()
      |> Map.put("_base_config", %{})
      |> Map.put("hook_timeout_ms", "0")

    assert {:error, "Hook timeout must be a positive integer"} =
             SymphonyElixir.WorkflowForm.to_raw(draft)

    assert SymphonyElixir.WorkflowForm.field_errors(draft) == %{
             "hook_timeout_ms" => "Hook timeout must be a positive integer"
           }
  end

  test "workflow form rejects invalid initialize timeout" do
    draft =
      workflow_form_params()
      |> Map.put("_base_config", %{})
      |> Map.put("initialize_timeout_ms", "0")

    assert {:error, "Initialize timeout must be a positive integer"} =
             SymphonyElixir.WorkflowForm.to_raw(draft)

    assert SymphonyElixir.WorkflowForm.field_errors(draft) == %{
             "initialize_timeout_ms" => "Initialize timeout must be a positive integer"
           }
  end

  test "workflow page shows local field errors before import" do
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

    assert html =~ "Field errors"
    assert html =~ "local field format issues"
    assert html =~ "workflow-field-polling-interval-ms"
    assert html =~ "field-invalid"
    assert html =~ "workflow-save-toast-error"
    assert html =~ "Workflow settings save failed"
    assert html =~ "Fix highlighted fields before saving."
    assert html =~ "Polling interval must be a positive integer"
    refute html =~ "Configuration check failed"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)
  end

  test "workflow page renders disk guard threshold as GiB" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/settings/workflow")

    assert html =~ "Minimum free GiB"
    assert html =~ ~s(name="workflow[workspace_min_free_gib]")
    refute html =~ "Minimum free bytes"
    refute html =~ "1073741824"
  end

  test "workflow page saves parseable drafts with semantic configuration errors" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/workflow")

    params =
      workflow_page_form_params()
      |> Map.put("allowed_transitions", %{
        "0" => %{"from" => "In Progress", "to" => "Unknown Review", "actor" => "codex", "profile" => "implementation"}
      })

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "workflow-save-toast-success"
    assert html =~ "Workflow settings saved"
    assert html =~ "Configuration check failed"
    assert html =~ "allowed_transitions.to"
    assert html =~ "Configuration check targets"
    assert html =~ "Allowed transition 1"
    assert html =~ "workflow-transition-row settings-check-invalid"
    assert html =~ "settings-check-message"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_workflow_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_workflow_settings"} -> true
               _ -> false
             end)

    assert raw =~ "\"to\": \"Unknown Review\""
  end

  test "agent settings highlights profile-owned semantic check failures" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/agents")

    params = %{
      "profiles" => %{
        "implementation" => %{
          "target_states" => "Needs Implementation Review"
        }
      }
    }

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "workflow-save-toast-success"
    assert html =~ "Agent settings saved"
    assert html =~ "Configuration check failed"
    assert html =~ "implementation allowed target states"
    assert html =~ "profile-implementation-target-states"
    assert html =~ "settings-check-invalid"
    assert html =~ "settings-check-title-invalid"
    assert html =~ "Linear state name limit of 25 characters"
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

  test "workflow settings page switches project via query parameter" do
    refute Process.whereis(SymphonyElixir.Repo)

    {:ok, project_a} = FakePersistence.default_project()

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Second Project",
        slug: "second",
        linear_project_slug: "second-project",
        repository_url: "git@github.com:org/repo-b.git"
      })

    b_raw =
      workflow_import_raw("git@github.com:org/repo-b.git")
      |> String.replace(
        "polling:\n  interval_ms: 30000",
        "hooks:\n  after_create: \"echo project-b\"\npolling:\n  interval_ms: 30000"
      )

    {:ok, _} = FakePersistence.import_workflow(project_a, workflow_import_raw("git@github.com:org/repo-a.git"), "web_workflow_settings")
    {:ok, _} = FakePersistence.import_workflow(project_b, b_raw, "web_workflow_settings")
    start_test_endpoint()

    {:ok, _view, default_html} = live(build_conn(), "/settings/workflow")
    refute default_html =~ "echo project-b"
    assert default_html =~ ~s(value="/settings/workflow?project=fake-project-id")

    {:ok, _view, b_html} = live(build_conn(), "/settings/workflow?project=#{project_b.id}")
    assert b_html =~ "echo project-b"
    assert b_html =~ ~s(value="/settings/workflow?project=#{project_b.id}")
  end

  test "workflow settings selects the first enabled project when no default project exists" do
    refute Process.whereis(SymphonyElixir.Repo)

    assert {:ok, _disabled} = FakePersistence.update_project("fake-project-id", %{enabled: false})

    {:ok, enabled_project} =
      FakePersistence.create_project(%{
        name: "Enabled Project",
        slug: "enabled",
        linear_project_slug: "enabled-project",
        repository_url: "git@github.com:org/enabled.git",
        enabled: true
      })

    raw =
      workflow_import_raw("git@github.com:org/enabled.git")
      |> String.replace(
        "polling:\n  interval_ms: 30000",
        "hooks:\n  after_create: \"echo enabled-project\"\npolling:\n  interval_ms: 30000"
      )

    assert {:ok, _version} = FakePersistence.import_workflow(enabled_project, raw, "web_workflow_settings")
    Application.put_env(:symphony_elixir, :persistence_module, NoDefaultPersistence)
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/settings/workflow")

    assert html =~ "echo enabled-project"
    refute html =~ "Project configuration checklist"
  end

  test "workflow save targets the selected project and leaves other projects untouched" do
    refute Process.whereis(SymphonyElixir.Repo)

    {:ok, project_a} = FakePersistence.default_project()

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Second Project",
        slug: "second",
        linear_project_slug: "second-project",
        repository_url: "git@github.com:org/repo-b.git"
      })

    {:ok, _} = FakePersistence.import_workflow(project_a, workflow_import_raw("git@github.com:org/repo-a.git"), "web_workflow_settings")
    {:ok, _} = FakePersistence.import_workflow(project_b, workflow_import_raw("git@github.com:org/repo-b.git"), "web_workflow_settings")
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/workflow?project=#{project_b.id}")

    saved_html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert saved_html =~ "Workflow settings saved"

    imports =
      Enum.filter(FakePersistence.calls(), fn
        {:import_workflow, _project, _raw, "web_workflow_settings"} -> true
        _ -> false
      end)

    assert length(imports) == 3

    assert Enum.any?(imports, fn
             {:import_workflow, project, _raw, "web_workflow_settings"} -> project.id == project_b.id
             _ -> false
           end)

    a_version = FakePersistence.current_workflow(project_a)
    assert a_version.raw_workflow_md =~ "git@github.com:org/repo-a.git"
    refute a_version.raw_workflow_md =~ "git@github.com:org/repo-b.git"
  end

  test "settings header renders project switcher and preserves project in tab links" do
    refute Process.whereis(SymphonyElixir.Repo)

    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Second Project",
        slug: "second",
        linear_project_slug: "second-project",
        repository_url: "git@github.com:org/repo-b.git"
      })

    start_test_endpoint()

    {:ok, _view, default_html} = live(build_conn(), "/settings/workflow")
    assert default_html =~ "All projects"
    assert default_html =~ "Fake Project"
    assert default_html =~ "Second Project"
    assert default_html =~ ~s(value="/settings/workflow?project=fake-project-id")
    assert default_html =~ ~s(href="/settings/agents")
    refute default_html =~ ~s(href="/settings/agents?project=)

    {:ok, _view, b_html} = live(build_conn(), "/settings/workflow?project=#{project_b.id}")
    assert b_html =~ ~s(value="/settings/workflow?project=#{project_b.id}")
    assert b_html =~ ~s(href="/settings/agents?project=#{project_b.id}")
    assert b_html =~ ~s(href="/settings/projects?project=#{project_b.id}")
  end

  defp start_test_endpoint(overrides \\ []) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp dashboard_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: %{},
      polling: %{listening?: false, listening_mode: "not_listening"},
      operator_tasks: %{
        nap: %{status: "running", project_id: "fake-project-id", summary: nil},
        day_dreaming: %{status: "idle", project_id: nil, summary: nil}
      }
    }
  end

  defp workflow_form_params do
    %{
      "tracker_project_slug" => "project",
      "tracker_assignee" => "",
      "active_states" => "Todo\nReady\nIn Progress",
      "terminal_states" => "Canceled\nCancelled\nDuplicate\nDone",
      "polling_interval_ms" => "30000",
      "project_repository_url" => "git@github.com:org/repo.git",
      "project_default_branch" => "main",
      "project_checkout_depth" => "1",
      "project_setup_commands" => "mix deps.get",
      "project_cleanup_commands" => "",
      "workspace_root" => "/tmp/symphony-workspaces",
      "initialize_timeout_ms" => "60000",
      "agent_max_concurrent_agents" => "1",
      "agent_max_turns" => "20",
      "codex_command" => "codex app-server",
      "codex_pre_start_commands" => "",
      "codex_approval_policy" => "never",
      "codex_thread_sandbox" => "workspace-write",
      "codex_turn_sandbox_preset" => "workspace_write_no_network",
      "codex_turn_sandbox_json" => "",
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
    |> Map.delete("project_checkout_depth")
  end

  defp split_workflow_yaml do
    WorkflowFixtures.settings_workflow_yaml()
  end

  defp split_profiles_yaml do
    WorkflowFixtures.settings_profiles_yaml()
  end

  defp workflow_raw!(params) do
    WorkflowForm.empty()
    |> Map.merge(params)
    |> Map.put("_base_config", %{})
    |> WorkflowForm.to_raw()
    |> case do
      {:ok, raw} -> raw
      {:error, reason} -> flunk("expected workflow params to render as raw workflow, got: #{inspect(reason)}")
    end
  end

  defp workflow_record(id, source, raw, inserted_at) do
    %{
      id: id,
      project_id: "fake-project-id",
      source: source,
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
      "human_review_states" => ["Ready to Merge"],
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
      active_states: ["Todo", "Ready", "In Progress"]
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
        Todo:
          profile: refinement
        Refining:
          profile: refinement
        Ready:
          profile: implementation
        In Progress:
          profile: implementation
      human_review_states: ["Needs Refinement Review", "Ready to Merge"]
      allowed_transitions:
        - {from: Todo, to: Refining, actor: codex, profile: refinement}
        - {from: Refining, to: Needs Refinement Review, actor: codex, profile: refinement}
        - {from: Needs Refinement Review, to: Refining, actor: human, profile: refinement}
        - {from: Ready, to: In Progress, actor: codex, profile: implementation}
        - {from: In Progress, to: Ready to Merge, actor: codex, profile: implementation}
        - {from: Ready to Merge, to: In Progress, actor: human, profile: implementation}
        - {from: Todo, to: Blocked, actor: symphony}
        - {from: Ready, to: Blocked, actor: symphony}
        - {from: In Progress, to: Blocked, actor: symphony}
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
