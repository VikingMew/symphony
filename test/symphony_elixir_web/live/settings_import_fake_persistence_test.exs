defmodule SymphonyElixirWeb.Live.SettingsImportFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Config.ProjectAuthority
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.TestSupport.WorkflowFixtures
  alias SymphonyElixir.{Workflow, WorkflowForm}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "settings import package reports parse errors without saving" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/import")

    html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{
          "yaml" => "workflow: ["
        }
      )
      |> render_submit()

    assert html =~ "Package import failed"

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end) == false
  end

  test "project-scope import requires an explicit target" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/import")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']",
        import: %{"yaml" => WorkflowFixtures.settings_workflow_yaml()}
      )
      |> render_submit()

    assert staged_html =~ "Project — no target selected"
    rejected_html = render_click(view, "confirm_settings_import")
    assert rejected_html =~ "Project target required"
    assert rejected_html =~ "project_target_required"

    assert Enum.all?(FakePersistence.calls(), fn
             {:import_package, _project, _raw, _source} -> false
             _ -> true
           end)
  end

  test "initialization-timeout-only import confirms without a project target" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/import")

    yaml =
      WorkflowForm.empty()
      |> workflow_config!()
      |> Map.delete("profiles")
      |> put_in(["workspace", "initialize_timeout_ms"], 61_000)
      |> WorkflowFixtures.workflow_package_yaml()

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => yaml})
      |> render_submit()

    assert staged_html =~ "Review staged import"
    assert staged_html =~ "Durable scopes"
    assert staged_html =~ "Instance"
    assert staged_html =~ "workspace.initialize_timeout_ms"
    assert staged_html =~ "61000"

    assert staged_html
           |> Floki.parse_document!()
           |> Floki.find(".settings-import-scope-group h4")
           |> Floki.text(deep: false)
           |> String.trim() == "Instance"

    confirmed_html = render_click(view, "confirm_settings_import")

    assert confirmed_html =~ "Instance settings imported"

    assert Enum.any?(FakePersistence.calls(), fn
             {:put_instance_workflow, config, _prompt} ->
               get_in(config, ["workspace", "initialize_timeout_ms"]) == 61_000

             _other ->
               false
           end)

    assert Enum.all?(FakePersistence.calls(), fn
             {:import_package, _project, _raw, _source} -> false
             {:import_workflow, _project, _raw, _source} -> false
             _other -> true
           end)
  end

  test "settings import rejects a Linear project scope without a team before persistence" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    assert {:ok, {:workflow, config}} =
             Workflow.parse_settings_yaml(WorkflowFixtures.settings_workflow_yaml())

    yaml =
      config
      |> Map.put("dispatch_scope", %{"linear_project_slug" => "koroni"})
      |> WorkflowFixtures.workflow_package_yaml()

    {:ok, view, _html} = live(build_conn(), "/settings/import")

    rejected_html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => yaml})
      |> render_submit()

    assert rejected_html =~ "Package import failed"
    assert rejected_html =~ "linear_project_requires_team"

    refute Enum.any?(FakePersistence.calls(), fn
             {:put_instance_workflow, _config, _prompt} -> true
             {:import_package, _project, _raw, _source} -> true
             _other -> false
           end)
  end

  test "legacy Codex command import stages conversion details and applies selector values" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/settings/import?project=fake-project-id")

    legacy_yaml = """
    codex:
      command: codex --config 'model="gpt-5.5"' -c model_reasoning_effort=xhigh app-server
    """

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => legacy_yaml})
      |> render_submit()

    assert staged_html =~ "Review staged import"
    assert staged_html =~ "codex.command"
    assert staged_html =~ "codex app-server"
    assert staged_html =~ "codex.model"
    assert staged_html =~ "gpt-5.5"
    assert staged_html =~ "codex.reasoning_effort"
    assert staged_html =~ "xhigh"

    view
    |> element("button[phx-click='confirm_settings_import']")
    |> render_click()

    runtime_html = render_patch(view, "/settings/runtime")

    assert has_element?(view, "#workflow-codex-model option[selected][value='gpt-5.5']")

    assert has_element?(
             view,
             "#workflow-codex-reasoning-effort option[selected][value='xhigh']"
           )

    assert runtime_html =~ "Use Codex default"
    assert runtime_html =~ "Use selected model or Codex default"
  end

  test "combined import shows and rejects project authority conflicts without durable writes" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, project} = FakePersistence.default_project()
    baseline_instance = FakePersistence.instance_workflow()
    baseline_workflow = FakePersistence.current_workflow(project)
    baseline_publications = FakePersistence.runtime_publication_count()

    conflicting_yaml =
      String.replace(
        WorkflowFixtures.settings_workflow_yaml(),
        project.repository_url,
        "git@github.com:org/conflict.git"
      )

    {:ok, view, _html} = live(build_conn(), "/settings/import?project=fake-project-id")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => conflicting_yaml})
      |> render_submit()

    assert staged_html =~ "project.repository_url"
    assert staged_html =~ "git@github.com:org/conflict.git"

    rejected_html = render_click(view, "confirm_settings_import")
    assert rejected_html =~ "project_authority_conflict"
    assert rejected_html =~ "installed_value"
    assert rejected_html =~ "git@github.com:org/repo.git"
    assert rejected_html =~ "package_value"
    assert rejected_html =~ "git@github.com:org/conflict.git"
    assert FakePersistence.instance_workflow() == baseline_instance
    assert FakePersistence.current_workflow(project) == baseline_workflow
    assert FakePersistence.runtime_publication_count() == baseline_publications
  end

  test "combined import inherits omitted project authority and persists only the minimal slice" do
    assert Process.whereis(SymphonyElixir.Repo) == nil
    start_test_endpoint()

    {:ok, project} = FakePersistence.default_project()
    assert {:ok, {:workflow, config}} = Workflow.parse_settings_yaml(WorkflowFixtures.settings_workflow_yaml())

    yaml =
      config
      |> ProjectAuthority.strip()
      |> put_in([Access.key("project", %{}), "setup_commands"], ["mix omitted-authority"])
      |> WorkflowFixtures.workflow_package_yaml()

    {:ok, view, _html} = live(build_conn(), "/settings/import?project=fake-project-id")

    staged_html =
      view
      |> form("form[phx-submit='stage_settings_import']", import: %{"yaml" => yaml})
      |> render_submit()

    assert staged_html =~ "project.setup_commands"
    assert staged_html =~ "project.repository_url" == false

    confirmed_html = render_click(view, "confirm_settings_import")
    assert confirmed_html =~ "Instance and Project settings imported"

    workflow = FakePersistence.current_workflow(project)
    assert ProjectAuthority.carrier_values(workflow.yaml_config) == %{}
    assert get_in(workflow.yaml_config, ["project", "setup_commands"]) == ["mix omitted-authority"]

    assert {:ok, loaded} = FakePersistence.workflow_to_loaded(FakePersistence.instance_workflow(), workflow)
    assert get_in(loaded.config, ["tracker", "project_slug"]) == project.linear_project_slug
    assert get_in(loaded.config, ["project", "repository_url"]) == project.repository_url
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp workflow_config!(draft) do
    case WorkflowForm.to_config(draft) do
      {:ok, config} -> config
      {:error, reason} -> flunk("expected workflow config, got #{inspect(reason)}")
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
