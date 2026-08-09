defmodule SymphonyElixirWeb.Live.SettingsProjectsLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule ProjectRemovalPersistence do
    @moduledoc false

    alias SymphonyElixir.TestSupport.FakePersistence

    defdelegate default_project(), to: FakePersistence
    defdelegate list_projects(), to: FakePersistence
    defdelegate active_workflow_version(project), to: FakePersistence
    defdelegate workflow_to_loaded(version), to: FakePersistence
    defdelegate export_workflow(version), to: FakePersistence
    defdelegate list_workflow_versions(project), to: FakePersistence
    defdelegate list_runs_page(opts), to: FakePersistence
    defdelegate list_events(opts), to: FakePersistence
    defdelegate list_tasks(opts), to: FakePersistence
    defdelegate list_task_leases(opts), to: FakePersistence

    def delete_project(id) do
      Agent.get_and_update(FakePersistence, &delete_project(&1, id))
    end

    defp delete_project(state, id) do
      case Enum.find(state.projects, &(Map.get(&1, :id) == id)) do
        nil -> {{:error, :not_found}, state}
        project -> {{:ok, project}, remove_project(state, id)}
      end
    end

    defp remove_project(state, id) do
      state
      |> Map.update!(:calls, &[{:delete_project, id} | &1])
      |> Map.update!(:projects, &Enum.reject(&1, fn candidate -> candidate.id == id end))
      |> Map.update!(:workflow_versions, &Enum.reject(&1, fn version -> version.project_id == id end))
      |> clear_active_workflow(id)
    end

    defp clear_active_workflow(%{active_workflow_version: %{project_id: project_id}} = state, project_id) do
      %{state | active_workflow_version: nil}
    end

    defp clear_active_workflow(state, _project_id), do: state
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)

    Application.put_env(:symphony_elixir, :persistence_module, ProjectRemovalPersistence)

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "remove project deletes it, flashes success, refreshes, and selects the first enabled fallback" do
    {:ok, fallback_project} =
      FakePersistence.create_project(%{
        name: "Fallback Project",
        slug: "fallback",
        linear_project_slug: "fallback",
        repository_url: "git@github.com:org/fallback.git",
        enabled: true
      })

    start_test_endpoint()
    {:ok, view, _html} = live(build_conn(), "/settings/projects?project=fake-project-id")

    button = ~s(button[phx-click="remove_project"][phx-value-project_id="fake-project-id"])
    assert has_element?(view, button <> "[data-confirm]")
    html = view |> element(button) |> render_click()

    assert html =~ "Project Fake Project removed."
    refute has_element?(view, ~s(.project-edit-form[data-project-id="fake-project-id"]))
    assert has_element?(view, ~s(.project-edit-form[data-project-id="#{fallback_project.id}"]))

    assert has_element?(
             view,
             ~s(option[value="/settings/projects?project=#{fallback_project.id}"][selected])
           )

    assert {:delete_project, "fake-project-id"} in FakePersistence.calls()
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
