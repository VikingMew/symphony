defmodule SymphonyElixirWeb.Live.SettingsFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Config.WorkflowScopes

  alias SymphonyElixir.TestSupport.FakePersistence

  alias SymphonyElixir.TestSupport.WorkflowFixtures

  alias SymphonyElixir.{WorkflowForm, WorkflowStore}

  alias SymphonyElixirWeb.Admin.SettingsCheck

  @endpoint SymphonyElixirWeb.Endpoint

  @worker_token "fake-worker-token"

  import SymphonyElixir.TestSupport.SettingsFakePersistenceSupport

  alias SymphonyElixir.TestSupport.SettingsFakePersistenceSupport.{
    FakeLinearClient,
    NoDefaultPersistence
  }

  defmodule BusyOperatorOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    defdelegate init(opts),
      to: SymphonyElixir.TestSupport.SettingsFakePersistenceSupport,
      as: :busy_init

    @impl true
    defdelegate handle_call(message, from, snapshot),
      to: SymphonyElixir.TestSupport.SettingsFakePersistenceSupport,
      as: :busy_handle_call
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)

    previous_linear_client =
      Application.get_env(:symphony_elixir, :linear_diagnostics_client_module)

    previous_linear_fake = Application.get_env(:symphony_elixir, :linear_discovery_fake)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: @worker_token)
    Application.put_env(:symphony_elixir, :linear_diagnostics_client_module, FakeLinearClient)
    System.put_env("LINEAR_API_KEY", "fake-linear-token")
    FakePersistence.reset!()
    :ok = WorkflowStore.force_reload()

    on_exit(fn ->
      FakePersistence.reset!()
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
    assert Process.whereis(SymphonyElixir.Repo) == nil
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

    field_names =
      html
      |> Floki.parse_document!()
      |> Floki.find(".project-edit-form input, .project-edit-form select, .project-edit-form textarea")
      |> Floki.attribute("name")
      |> Enum.uniq()
      |> Enum.sort()

    assert field_names ==
             Enum.sort([
               "project[active_states]",
               "project[checkout_depth]",
               "project[default_branch]",
               "project[description]",
               "project[enabled]",
               "project[id]",
               "project[linear_project_slug]",
               "project[name]",
               "project[project_cleanup_commands]",
               "project[project_setup_commands]",
               "project[repository_url]",
               "project[slug]",
               "project[source_strategy]",
               "project[terminal_states]",
               "project[tracker_assignee]",
               "project[worktree_cleanup]",
               "project[worktree_fetch]"
             ])
  end

  test "dashboard shows a friendly flash when a nap is already running" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    orchestrator_name = Module.concat(__MODULE__, :BusyDashboardOperator)

    start_supervised!({BusyOperatorOrchestrator, name: orchestrator_name, snapshot: dashboard_snapshot()})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view |> form("#request-nap-form", %{"project_id" => "fake-project-id"}) |> render_submit()

    assert html =~ "Take a nap failed: a nap run is already in progress for this project"
  end

  test "project settings exposes read-only Linear discovery" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
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
    assert length(Regex.scan(~r/Refresh Linear configuration/, projects_html)) == 1
  end

  test "project settings page shows Linear discovery errors inline" do
    System.delete_env("LINEAR_API_KEY")
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, html} = live(build_conn(), "/settings/projects")
    assert html =~ "Linear Configuration Discovery"
    error_html = render_click(view, "fetch_linear_discovery")
    assert error_html =~ "Discovery failed"
    assert error_html =~ "missing_linear_api_token"
    assert error_html =~ "Projects"
  end

  test "agent settings setup-required page does not expose setup prompt as base prompt" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, _view, html} = live(build_conn(), "/settings/agents")
    assert html =~ "Base Prompt"
    assert html =~ ~s(name="workflow[prompt_body]")
  end

  test "Runtime and Agents save with zero projects" do
    Application.put_env(:symphony_elixir, :persistence_module, NoDefaultPersistence)
    assert {:ok, _project} = FakePersistence.delete_project("fake-project-id")
    start_test_endpoint()
    {:ok, runtime_view, runtime_html} = live(build_conn(), "/settings/runtime")
    assert runtime_html =~ "All projects"

    runtime_saved =
      runtime_view
      |> form(".runtime-settings-form", workflow: %{"workspace_root" => "/tmp/zero-projects"})
      |> render_submit()

    assert runtime_saved =~ "Workflow settings saved installation-wide"
    assert runtime_saved =~ "No enabled project snapshots required refresh"
    {:ok, agents_view, _agents_html} = live(build_conn(), "/settings/agents")

    agents_saved =
      agents_view
      |> form(".agent-settings-form", workflow: %{"prompt_body" => "Shared without projects."})
      |> render_submit()

    assert agents_saved =~ "Agent settings saved installation-wide"
    assert FakePersistence.instance_workflow().prompt_body == "Shared without projects."
  end

  test "project selector changes do not change instance settings" do
    {:ok, project_b} =
      FakePersistence.create_project(%{
        name: "Second Project",
        slug: "second",
        linear_project_slug: "second-project",
        repository_url: "git@github.com:org/repo-b.git",
        enabled: true
      })

    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/agents")

    view
    |> form(".agent-settings-form", workflow: %{"prompt_body" => "One installation prompt."})
    |> render_submit()

    selected_html = render_patch(view, "/settings/agents?project=#{project_b.id}")
    assert selected_html =~ "One installation prompt."
    assert selected_html =~ ~s(value="/settings/agents?project=#{project_b.id}")
  end

  test "legacy drift requires an explicit source and refreshes after reconciliation" do
    {:ok, base} = WorkflowForm.empty() |> WorkflowForm.to_instance_scope()
    alternate = put_in(base.config["workspace"]["root"], "/tmp/alternate")

    conflict = %{
      "candidates" => [
        %{
          "project_id" => "fake-project-id",
          "project_slug" => "fake",
          "candidate" => WorkflowScopes.dump_instance(base)
        },
        %{
          "project_id" => "other-project-id",
          "project_slug" => "other",
          "candidate" => WorkflowScopes.dump_instance(alternate)
        }
      ],
      "differing_paths" => [
        %{
          "path" => "workspace.root",
          "contributors" => [
            %{
              "project_id" => "fake-project-id",
              "project_slug" => "fake",
              "present" => true,
              "value" => base.config["workspace"]["root"]
            },
            %{
              "project_id" => "other-project-id",
              "project_slug" => "other",
              "present" => true,
              "value" => "/tmp/alternate"
            }
          ]
        }
      ]
    }

    FakePersistence.put_legacy_instance_workflow_conflict!(conflict)
    start_test_endpoint()
    {:ok, view, html} = live(build_conn(), "/settings/runtime")
    assert html =~ "Legacy instance settings differ across projects"
    assert html =~ "workspace.root"
    assert html =~ "fake"
    assert html =~ "other"
    assert has_element?(view, "button[phx-click='reconcile_legacy_instance_workflow'][disabled]")
    selected_html = render_patch(view, "/settings/runtime?project=fake-project-id")
    assert selected_html =~ "Selected source:"

    assert has_element?(
             view,
             "button[phx-click='reconcile_legacy_instance_workflow']:not([disabled])"
           )

    reconciled_html = render_click(view, "reconcile_legacy_instance_workflow")
    assert reconciled_html =~ "Legacy instance settings reconciled"
    assert reconciled_html =~ "fake was used as the explicit source"
    assert {:reconcile_legacy_instance_workflow, "fake"} in FakePersistence.calls()

    assert SettingsCheck.legacy_instance_drift(elem(FakePersistence.legacy_instance_workflow_status(), 1)) == nil
  end

  test "settings import package writes instance and project scopes together" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, _agents_view, _agents_html} = live(build_conn(), "/settings/agents")
    {:ok, view, html} = live(build_conn(), "/settings/import?project=fake-project-id")
    assert html =~ "Import Settings Package"
    assert html =~ ~s(name="import[yaml]")
    assert html =~ ">Review import</button>"

    workflow_staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{"yaml" => split_workflow_yaml()}
      )
      |> render_submit()

    assert workflow_staged_html =~ "workflow.yml staged"
    assert workflow_staged_html =~ "Detected"
    assert workflow_staged_html =~ "workflow.yml"
    assert workflow_staged_html =~ "Instance"
    assert workflow_staged_html =~ "Project — Fake Project (fake)"
    imported_html = render_click(view, "confirm_settings_import")
    assert imported_html =~ "Instance and Project settings imported"
    assert imported_html =~ "both durable scopes saved"

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_package, _project, _raw, "web_settings_import"} -> true
             _ -> false
           end)
  end

  test "settings import profiles package writes the instance singleton" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/import")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{"yaml" => split_profiles_yaml()}
      )
      |> render_submit()

    assert staged_html =~ "profiles.yml staged"
    imported_html = render_click(view, "confirm_settings_import")
    assert imported_html =~ "Instance settings imported"
    assert String.trim(FakePersistence.instance_workflow().prompt_body) == "Imported base prompt."
    agents_draft_html = render_patch(view, "/settings/agents")
    assert agents_draft_html =~ "Imported base prompt."
    assert agents_draft_html =~ "Imported implementation prompt."
  end

  @tag :tmp_dir
  test("normal Settings save rejects an invalid workspace root before persistence", %{
    tmp_dir: tmp_dir
  }) do
    invalid_root = Path.join(tmp_dir, "workspace-file")
    File.write!(invalid_root, "not a directory")
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/agents")
    current_before = WorkflowStore.current()
    writes_before = persistence_write_count()

    rejected_html =
      render_submit(view, "save_workflow_form", %{
        "workflow" => %{
          "workspace_root" => invalid_root,
          "prompt_body" => "Draft retained after root rejection."
        }
      })

    assert rejected_html =~ "Agent settings save failed"
    assert rejected_html =~ Path.expand(invalid_root)
    assert rejected_html =~ "cannot be created"
    assert rejected_html =~ "Settings / Import: workspace.root"
    assert rejected_html =~ "/data/workspaces"
    assert WorkflowStore.current() == current_before
    assert persistence_write_count() == writes_before

    retained_html =
      view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: %{"prompt_body" => "Draft retained after root rejection."}
      )
      |> render_submit()

    assert retained_html =~ Path.expand(invalid_root)
    assert persistence_write_count() == writes_before
  end

  @tag :tmp_dir
  test("confirmed Settings import uses the same workspace root gate before package persistence", %{
    tmp_dir: tmp_dir
  }) do
    invalid_root = Path.join(tmp_dir, "workspace-file")
    File.write!(invalid_root, "not a directory")
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/import?project=fake-project-id")
    current_before = WorkflowStore.current()
    writes_before = persistence_write_count()

    invalid_yaml =
      String.replace(
        WorkflowFixtures.settings_workflow_yaml(),
        "/tmp/imported-workspaces",
        invalid_root
      )

    view
    |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => invalid_yaml})
    |> render_submit()

    rejected_html = render_click(view, "confirm_settings_import")
    assert rejected_html =~ "Package import failed"
    assert rejected_html =~ Path.expand(invalid_root)
    assert rejected_html =~ "cannot be created"
    assert rejected_html =~ "Settings / Import: workspace.root"
    assert rejected_html =~ "/data/workspaces"
    assert WorkflowStore.current() == current_before
    assert persistence_write_count() == writes_before

    valid_yaml =
      String.replace(
        WorkflowFixtures.settings_workflow_yaml(),
        "/tmp/imported-workspaces",
        tmp_dir
      )

    view
    |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => valid_yaml})
    |> render_submit()

    saved_html = render_click(view, "confirm_settings_import")
    assert saved_html =~ "Instance and Project settings imported"
    assert get_in(FakePersistence.instance_workflow(), [:config, "workspace", "root"]) == tmp_dir

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_package, _project, _raw, "web_settings_import"} -> true
             _call -> false
           end)
  end

  test "settings import accepts uploaded package files and can cancel staged changes" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, html} = live(build_conn(), "/settings/import")
    assert html =~ "Upload file"

    upload =
      file_input(view, "form[phx-submit='stage_settings_import']", :settings_package, [
        %{name: "profiles.yml", content: split_profiles_yaml(), type: "text/yaml"}
      ])

    render_upload(upload, "profiles.yml")

    html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => ""})
      |> render_submit()

    assert html =~ "profiles.yml staged"
    assert render_click(view, "cancel_settings_import") =~ "Import cancelled"
    _agents_html = render_patch(view, "/settings/agents")
  end

  test "settings configuration checklists stay on their owning pages" do
    System.delete_env("LINEAR_API_KEY")
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    assert {:ok, _project} =
             FakePersistence.update_project("fake-project-id", %{
               linear_project_slug: nil,
               repository_url: nil
             })

    {:ok, _view, projects_html} = live(build_conn(), "/settings/projects")
    assert projects_html =~ "Project configuration checklist"
    assert projects_html =~ "Linear project slug"
    assert projects_html =~ "Repository URL"
    assert projects_html =~ "settings-check-invalid"
    assert projects_html =~ "settings-check-title-invalid"
    {:ok, _view, runtime_html} = live(build_conn(), "/settings/runtime")
    assert runtime_html =~ "Runtime configuration checklist"
    assert runtime_html =~ "Linear API token"
    assert runtime_html =~ "Set LINEAR_API_KEY"
  end

  test "agent settings page saves the shared prompt and profiles installation-wide" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

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
        "implementation" => %{"prompt_template" => "Changed implementation profile prompt."}
      }
    }

    html =
      view |> form("form[phx-submit='save_workflow_form']", workflow: params) |> render_submit()

    assert html =~ "Agent settings saved installation-wide"
    assert html =~ "Future runtime snapshots refreshed for enabled projects: Fake Project"
    assert FakePersistence.instance_workflow().prompt_body == "Changed shared base prompt."

    assert Enum.any?(FakePersistence.calls(), fn
             {:put_instance_workflow, _config, "Changed shared base prompt."} -> true
             _ -> false
           end)

    assert Enum.all?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> false
             _ -> true
           end)
  end
end
