defmodule SymphonyElixirWeb.Live.SettingsFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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

  test "project settings exposes read-only Linear discovery" do
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

    assert length(Regex.scan(~r/Refresh Linear configuration/, projects_html)) == 1
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

    render_patch(view, "/settings/agents")

    saved_html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_page_form_params())
      |> render_submit()

    assert saved_html =~ "Agent settings saved"

    {:ok, _agents_view, imported_agents_html} = live(build_conn(), "/settings/agents")
    assert imported_agents_html =~ "Imported base prompt."
    assert imported_agents_html =~ "Imported implementation prompt."
    assert imported_agents_html =~ "Save agent settings"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_agent_settings"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_agent_settings"} -> true
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

  test "settings configuration checklists stay on their owning pages" do
    System.delete_env("LINEAR_API_KEY")
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    assert {:ok, _project} = FakePersistence.update_project("fake-project-id", %{linear_project_slug: nil, repository_url: nil})

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

  test "settings pages do not expose workflow history or restore controls" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    for path <- ["/settings/agents"] do
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
    assert build_conn() |> get("/settings/workflow") |> response(404) =~ "Route not found"
    assert build_conn() |> get("/agent-settings") |> response(404) =~ "Route not found"
    assert build_conn() |> get("/projects") |> response(404) =~ "Route not found"
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

    {:ok, _view, default_html} = live(build_conn(), "/settings/agents")
    assert default_html =~ "All projects"
    assert default_html =~ "Fake Project"
    assert default_html =~ "Second Project"
    assert default_html =~ ~s(value="/settings/agents?project=fake-project-id")
    assert default_html =~ ~s(href="/settings/agents")
    refute default_html =~ ~s(href="/settings/agents?project=)

    {:ok, _view, b_html} = live(build_conn(), "/settings/agents?project=#{project_b.id}")
    assert b_html =~ ~s(value="/settings/agents?project=#{project_b.id}")
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

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
