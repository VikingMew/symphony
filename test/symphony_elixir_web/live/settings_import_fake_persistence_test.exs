defmodule SymphonyElixirWeb.Live.SettingsImportFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.TestSupport.WorkflowFixtures

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
