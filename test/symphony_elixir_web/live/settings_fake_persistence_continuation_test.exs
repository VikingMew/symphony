defmodule SymphonyElixirWeb.Live.SettingsFakePersistenceContinuationTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Config.ProjectAuthority

  alias SymphonyElixir.TestSupport.FakePersistence

  alias SymphonyElixir.WorkflowStore

  alias SymphonyElixirWeb.Admin.SettingsCheck

  alias SymphonyElixirWeb.AdminLive.Settings.Runtime

  @endpoint SymphonyElixirWeb.Endpoint

  @worker_token "fake-worker-token"

  import SymphonyElixir.TestSupport.SettingsFakePersistenceSupport

  alias SymphonyElixir.TestSupport.SettingsFakePersistenceSupport.FakeLinearClient

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
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:worker_api, previous_worker_api)
      restore_app_env(:linear_diagnostics_client_module, previous_linear_client)
      restore_app_env(:linear_discovery_fake, previous_linear_fake)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    :ok
  end

  test "settings tabs render only the active settings surface" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, _view, projects_html} = live(build_conn(), "/settings")
    assert projects_html =~ "Projects"
    assert projects_html =~ "Add Project"
    {:ok, _view, agents_html} = live(build_conn(), "/settings/agents")
    assert agents_html =~ "Profile Configuration"
    assert agents_html =~ "Base Prompt"
    {:ok, _view, runtime_html} = live(build_conn(), "/settings/runtime")
    assert runtime_html =~ "Execution mode:"
    assert runtime_html =~ "Codex Runtime"
  end

  @tag :tmp_dir
  test("runtime settings page saves workspace hooks and Codex selectors to the singleton", %{
    tmp_dir: tmp_dir
  }) do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

    start_test_endpoint()
    workspace_root = Path.join(tmp_dir, "workspaces")
    {:ok, view, html} = live(build_conn(), "/settings/runtime")
    assert html =~ "Codex Runtime"
    assert html =~ ~s(id="workflow-codex-model")
    assert html =~ ~s(name="workflow[codex_model]")
    assert html =~ "GPT-6-Astra (default medium)"
    assert html =~ "GPT-6-Sol (default medium)"
    assert html =~ "GPT-6-Luna (default medium)"
    assert html =~ "GPT-5.5"
    assert html =~ "GPT-5.3-Codex-Spark" == false
    assert html =~ "Use Codex default"
    assert html =~ "Use selected model or Codex default"
    assert html =~ ~s(id="workflow-codex-reasoning-effort")
    assert html =~ ~s(name="workflow[codex_reasoning_effort]")
    assert html =~ "ultra - Maximum reasoning with automatic task delegation"
    assert html =~ ~s(name="workflow[workspace_root]")
    assert html =~ ~s(name="workflow[workspace_repository_base_root]")
    assert html =~ ~s(name="workflow[workspace_worktree_base_root]")
    assert html =~ ~s(name="workflow[initialize_timeout_ms]")
    assert html =~ ~s(name="workflow[workspace_min_free_gib]")
    assert html =~ ~s(name="workflow[hook_after_create]")
    assert html =~ ~s(name="workflow[hook_before_run]")
    assert html =~ ~s(name="workflow[hook_after_run]")
    assert html =~ ~s(name="workflow[hook_before_remove]")
    assert html =~ ~s(name="workflow[codex_approval_policy]")
    assert html =~ ~s(name="workflow[codex_thread_sandbox]")
    assert html =~ ~s(name="workflow[codex_turn_sandbox_preset]")

    sol_html =
      view
      |> form(".runtime-settings-form",
        workflow: %{"codex_model" => "gpt-6-sol", "codex_reasoning_effort" => ""}
      )
      |> render_change()

    assert reasoning_effort_values(sol_html) == [
             "",
             "low",
             "medium",
             "high",
             "xhigh",
             "max",
             "ultra"
           ]

    luna_html =
      view
      |> form(".runtime-settings-form",
        workflow: %{"codex_model" => "gpt-6-luna", "codex_reasoning_effort" => ""}
      )
      |> render_change()

    assert reasoning_effort_values(luna_html) == ["", "low", "medium", "high", "xhigh", "max"]

    saved_html =
      view
      |> form(".runtime-settings-form",
        workflow: %{
          "workspace_root" => workspace_root,
          "workspace_repository_base_root" => Path.join(tmp_dir, "repositories"),
          "workspace_worktree_base_root" => Path.join(tmp_dir, "worktrees"),
          "initialize_timeout_ms" => "90000",
          "workspace_min_free_gib" => "2",
          "hook_after_create" => "mix setup",
          "hook_before_run" => "mix test",
          "hook_after_run" => "echo done",
          "hook_before_remove" => "echo cleanup",
          "hook_timeout_ms" => "45000",
          "codex_model" => "gpt-6-luna",
          "codex_reasoning_effort" => "max",
          "codex_approval_policy" => "never",
          "codex_thread_sandbox" => "workspace-write",
          "codex_turn_sandbox_preset" => "danger_full_access"
        }
      )
      |> render_submit()

    assert saved_html =~ "workflow-save-toast-success"
    assert saved_html =~ "Workflow settings saved installation-wide"
    instance = FakePersistence.instance_workflow()
    assert get_in(instance.config, ["workspace", "root"]) == workspace_root
    assert get_in(instance.config, ["hooks", "after_create"]) == "mix setup"
    assert get_in(instance.config, ["codex", "model"]) == "gpt-6-luna"
    assert get_in(instance.config, ["codex", "reasoning_effort"]) == "max"
    assert get_in(instance.config, ["codex", "turn_sandbox_policy", "type"]) == "dangerFullAccess"
    {:ok, _reloaded_view, reloaded_html} = live(build_conn(), "/settings/runtime")
    assert reloaded_html =~ ~s(id="workflow-codex-model")
    assert reloaded_html =~ ~s(id="workflow-codex-reasoning-effort")
  end

  test "settings import saves a new Codex model and Runtime reloads it" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/import")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{"yaml" => workflow_yaml_with_codex("gpt-6-sol", "ultra")}
      )
      |> render_submit()

    assert staged_html =~ "workflow.yml staged"
    assert staged_html =~ "gpt-6-sol"
    render_click(view, "confirm_settings_import")
    render_patch(view, "/settings/runtime")

    saved_html =
      view
      |> form(".runtime-settings-form",
        workflow: %{"codex_model" => "gpt-6-sol", "codex_reasoning_effort" => "ultra"}
      )
      |> render_submit()

    assert saved_html =~ "Workflow settings saved"
    assert get_in(FakePersistence.instance_workflow(), [:config, "codex", "model"]) == "gpt-6-sol"

    assert get_in(FakePersistence.instance_workflow(), [:config, "codex", "reasoning_effort"]) ==
             "ultra"

    {:ok, _reloaded_view, reloaded_html} = live(build_conn(), "/settings/runtime")
    assert selected_value(reloaded_html, "#workflow-codex-model") == "gpt-6-sol"
    assert selected_value(reloaded_html, "#workflow-codex-reasoning-effort") == "ultra"
  end

  test "Runtime renders Codex command failures on the implicated selectors" do
    message =
      "Invalid workflow config: codex.command must not set model or model_reasoning_effort; use the Settings / Runtime Codex model and reasoning effort selectors"

    targets = SettingsCheck.workflow_check_targets(%{}, message)

    html =
      render_component(&Runtime.render/1,
        execution_mode: :centralized,
        runtime_configuration_items: [],
        workflow_validation_visible?: true,
        workflow_field_errors: %{},
        workflow_validation_error: message,
        workflow_check_targets: targets,
        workflow_save_notice: nil,
        workflow_form: %{},
        runtime_workflow_source: %{type: "PostgreSQL", detail: "current workflow"}
      )

    assert html =~ "Configuration check failed:"
    assert html =~ "codex.command must not set model or model_reasoning_effort"
    assert html =~ ~s(id="workflow-codex-model")
    assert html =~ ~s(id="workflow-codex-reasoning-effort")
    assert length(Regex.scan(~r/settings-check-title-invalid/, html)) == 2
  end

  test "project settings page creates and updates projects" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/projects")
    publications_before_create = FakePersistence.runtime_publication_count()

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
    assert FakePersistence.runtime_publication_count() == publications_before_create + 1

    assert Enum.any?(FakePersistence.calls(), fn
             {:save_project_settings, nil, attrs, _raw} ->
               attrs.name == "Second Project" and
                 attrs.repository_url == "git@github.com:org/second.git" and
                 attrs.checkout_depth == 3 and attrs.source_strategy == "worktree" and
                 attrs.worktree_fetch == true and attrs.worktree_cleanup == false

             _ ->
               false
           end)

    created = Enum.find(FakePersistence.list_projects(), &(&1.slug == "second"))
    assert FakePersistence.current_workflow(created).prompt_body == ""
    publications_before_update = FakePersistence.runtime_publication_count()

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
    assert FakePersistence.runtime_publication_count() == publications_before_update + 1

    assert Enum.any?(FakePersistence.calls(), fn
             {:save_project_settings, "fake-project-id", attrs, _raw} ->
               attrs.name == "Renamed Project" and attrs.linear_project_slug == "renamed-linear"

             _ ->
               false
           end)
  end

  test "project settings rejects invalid durable writes atomically and remains usable" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/projects")

    baseline_params =
      project_settings_params(%{"repository_url" => "git@github.com:org/baseline.git"})

    baseline_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]), project: baseline_params)
      |> render_submit()

    assert baseline_html =~ "Project settings saved"
    baseline_project = Enum.find(FakePersistence.list_projects(), &(&1.id == "fake-project-id"))
    baseline_workflow = FakePersistence.current_workflow(baseline_project)
    publications_after_baseline = FakePersistence.runtime_publication_count()

    invalid_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: project_settings_params(%{"name" => ""})
      )
      |> render_submit()

    assert invalid_html =~ "workflow-save-toast-error"
    assert invalid_html =~ "Project settings failed"
    assert invalid_html =~ "can&#39;t be blank"

    assert Enum.find(FakePersistence.list_projects(), &(&1.id == "fake-project-id")) ==
             baseline_project

    assert FakePersistence.current_workflow(baseline_project) == baseline_workflow
    assert FakePersistence.runtime_publication_count() == publications_after_baseline
    FakePersistence.fail_next_import_workflow!(:injected_workflow_failure)

    rejected_params =
      project_settings_params(%{
        "repository_url" => "git@github.com:org/rejected.git",
        "source_strategy" => "worktree",
        "project_setup_commands" => "mix rejected"
      })

    rejected_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]), project: rejected_params)
      |> render_submit()

    assert rejected_html =~ "workflow-save-toast-error"
    assert rejected_html =~ "injected_workflow_failure"

    assert Enum.find(FakePersistence.list_projects(), &(&1.id == "fake-project-id")) ==
             baseline_project

    assert FakePersistence.current_workflow(baseline_project) == baseline_workflow
    assert FakePersistence.runtime_publication_count() == publications_after_baseline

    saved_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]), project: rejected_params)
      |> render_submit()

    assert saved_html =~ "workflow-save-toast-success"
    assert saved_html =~ "Project settings saved"
    saved_project = Enum.find(FakePersistence.list_projects(), &(&1.id == "fake-project-id"))
    saved_workflow = FakePersistence.current_workflow(saved_project)
    assert saved_project.repository_url == "git@github.com:org/rejected.git"
    assert saved_project.source_strategy == "worktree"
    assert get_in(saved_workflow.yaml_config, ["project", "setup_commands"]) == ["mix rejected"]
    assert saved_workflow.prompt_body == ""
    assert FakePersistence.runtime_publication_count() == publications_after_baseline + 1
    assert {:ok, runtime} = WorkflowStore.for_project(saved_project.id)

    assert get_in(runtime.config, ["project", "repository_url"]) ==
             "git@github.com:org/rejected.git"
  end

  test "project settings reports post-commit publication failure and retains the durable save" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/projects")
    publications_before = FakePersistence.runtime_publication_count()
    FakePersistence.fail_next_runtime_publication!({:refresh_failed, :injected})
    params = project_settings_params(%{"repository_url" => "git@github.com:org/durable.git"})

    failed_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]), project: params)
      |> render_submit()

    assert failed_html =~ "workflow-save-toast-error"
    assert failed_html =~ "runtime_publication_failed"
    durable_project = Enum.find(FakePersistence.list_projects(), &(&1.id == "fake-project-id"))
    assert durable_project.repository_url == "git@github.com:org/durable.git"
    assert FakePersistence.current_workflow(durable_project).prompt_body == ""
    assert FakePersistence.runtime_publication_count() == publications_before + 1

    saved_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]), project: params)
      |> render_submit()

    assert saved_html =~ "workflow-save-toast-success"
    assert FakePersistence.runtime_publication_count() == publications_before + 2
    assert {:ok, runtime} = WorkflowStore.for_project(durable_project.id)
    assert get_in(runtime.config, ["project", "repository_url"]) == "git@github.com:org/durable.git"
  end

  test "project settings save refreshes runtime project configuration" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

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

    assert get_in(workflow.config, ["project", "repository_url"]) ==
             "git@github.com:org/runtime.git"

    assert get_in(workflow.config, ["project", "default_branch"]) == "master"
    assert get_in(workflow.config, ["project", "source_strategy"]) == "worktree"
    assert Map.has_key?(get_in(workflow.config, ["project"]), "worktree_base_path") == false
    assert Map.has_key?(get_in(workflow.config, ["project"]), "worktree_root") == false
  end

  test "project settings shows legacy authority drift and save converges every carrier to clean" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    {:ok, project} = FakePersistence.default_project()
    {:ok, loaded} = SymphonyElixir.Workflow.load()

    legacy_config =
      loaded.config
      |> put_in([Access.key("tracker", %{}), "project_slug"], project.linear_project_slug)
      |> put_in([Access.key("project", %{}), "repository_url"], "git@github.com:org/legacy.git")
      |> put_in([Access.key("project", %{}), "default_branch"], project.default_branch)
      |> put_in([Access.key("project", %{}), "checkout_depth"], 9)
      |> put_in([Access.key("project", %{}), "source_strategy"], project.source_strategy)
      |> put_in([Access.key("project", %{}), "worktree_fetch"], false)
      |> put_in([Access.key("project", %{}), "worktree_cleanup"], project.worktree_cleanup)

    assert {:ok, _legacy} =
             FakePersistence.put_package_unchecked(project, legacy_config, loaded.prompt)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, runtime_before} = WorkflowStore.for_project(project.id)
    start_test_endpoint()
    {:ok, view, html} = live(build_conn(), "/settings/projects")
    statuses_before = authority_statuses(html)
    assert Enum.count(statuses_before, &(&1 == "legacy_duplicate")) == 4
    assert Enum.count(statuses_before, &(&1 == "conflict")) == 3

    saved_html =
      view
      |> form(~s(.project-edit-form[data-project-id="fake-project-id"]),
        project: project_settings_params(%{})
      )
      |> render_submit()

    assert authority_statuses(saved_html) == List.duplicate("clean", 7)
    workflow = FakePersistence.current_workflow(project)

    assert ProjectAuthority.diagnostics(project, workflow.yaml_config)
           |> Enum.all?(&(&1.status == :clean))

    assert {:ok, runtime_after} = WorkflowStore.for_project(project.id)

    assert runtime_after.config["tracker"]["project_slug"] ==
             runtime_before.config["tracker"]["project_slug"]

    assert runtime_after.config["project"]["repository_url"] ==
             runtime_before.config["project"]["repository_url"]
  end

  test "settings save controls show saving feedback and saved notices" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
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

    agent_saved_html =
      agent_view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: %{
          "prompt_body" => "Saved shared base prompt.",
          "profiles" => %{
            "implementation" => %{"prompt_template" => "Saved implementation profile prompt."}
          }
        }
      )
      |> render_submit()

    assert agent_saved_html =~ "workflow-save-toast-success"
    assert agent_saved_html =~ "Agent settings saved installation-wide"
    {:ok, _runtime_view, _runtime_html} = live(build_conn(), "/settings/runtime")
  end

  test "instance and project settings save through isolated persistence paths" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@github.com:org/repo.git"
    )

    start_test_endpoint()
    {:ok, agent_view, _agent_html} = live(build_conn(), "/settings/agents")

    agent_noop_html =
      agent_view
      |> form("form[phx-submit='save_workflow_form']",
        workflow: %{"prompt_body" => "You are an agent for this repository."}
      )
      |> render_submit()

    assert agent_noop_html =~ "workflow-save-toast-success"
    assert agent_noop_html =~ "Agent settings saved installation-wide"
    instance_after_agent_save = FakePersistence.instance_workflow()

    assert Enum.any?(FakePersistence.calls(), fn
             {:put_instance_workflow, _config, _prompt} -> true
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
          "tracker_assignee" => "ops@example.test",
          "active_states" => "Todo\nReady\nIn Progress",
          "terminal_states" => "Done\nCanceled\nCancelled\nDuplicate",
          "project_setup_commands" => "mix setup",
          "project_cleanup_commands" => "mix clean",
          "description" => "",
          "enabled" => "true"
        }
      )
      |> render_submit()

    assert project_noop_html =~ "workflow-save-toast-success"
    assert project_noop_html =~ "Project settings saved"
    assert FakePersistence.instance_workflow() == instance_after_agent_save

    assert Enum.any?(FakePersistence.calls(), fn
             {:save_project_settings, "fake-project-id", _attrs, _raw} -> true
             _ -> false
           end)

    workflow = FakePersistence.current_workflow(%{id: "fake-project-id"})
    assert get_in(workflow.yaml_config, ["tracker", "assignee"]) == "ops@example.test"
    assert get_in(workflow.yaml_config, ["project", "setup_commands"]) == ["mix setup"]
    assert get_in(workflow.yaml_config, ["project", "cleanup_commands"]) == ["mix clean"]
  end

  test "settings pages do not expose workflow history or restore controls" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    for path <- ["/settings/agents"] do
      {:ok, _view, _html} = live(build_conn(), path)
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
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/agents")

    params = %{
      "profiles" => %{"implementation" => %{"target_states" => "Needs Implementation Review"}}
    }

    html =
      view |> form("form[phx-submit='save_workflow_form']", workflow: params) |> render_submit()

    assert html =~ "workflow-save-toast-error"
    assert html =~ "Agent settings save failed"
    assert html =~ "exceeds Linear state name limit"
  end

  test "settings header renders project switcher and preserves project in tab links" do
    assert Process.whereis(SymphonyElixir.Repo) == nil

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
    {:ok, _view, b_html} = live(build_conn(), "/settings/agents?project=#{project_b.id}")
    assert b_html =~ ~s(value="/settings/agents?project=#{project_b.id}")
    assert b_html =~ ~s(href="/settings/agents?project=#{project_b.id}")
    assert b_html =~ ~s(href="/settings/projects?project=#{project_b.id}")
  end
end
