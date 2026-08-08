defmodule SymphonyElixirWeb.AdminLive.State do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias SymphonyElixir.{Config, PersistenceProvider, WorkflowStore}
  alias SymphonyElixirWeb.Admin.ProjectSettings

  alias SymphonyElixirWeb.AdminLive.{
    Events,
    IssueDetail,
    RunDetail,
    Runs,
    WorkflowState
  }

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    projects = persistence().list_projects()
    default_project = default_project()
    selected_project = selected_project(socket, projects, default_project)
    active = selected_project && persistence().active_workflow_version(selected_project)
    runtime = WorkflowStore.current_with_source()
    {loaded_workflow_form, workflow_setup_required} = WorkflowState.load_form(active, runtime)
    workflow_form = WorkflowState.refreshed_form(socket, loaded_workflow_form)

    configuration_items =
      ProjectSettings.configuration_missing_items(workflow_setup_required, default_project)

    socket
    |> assign(:projects, projects)
    |> assign(:default_project, default_project)
    |> assign(:selected_project, selected_project)
    |> assign(:active_workflow_version, active)
    |> Runs.assign_page(reset: true)
    |> Events.assign_data()
    |> assign(:tasks, persistence().list_tasks(limit: 100, project_id: project_filter(socket)))
    |> assign(:task_leases, persistence().list_task_leases(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
    |> assign(
      :workflow_versions,
      (selected_project && persistence().list_workflow_versions(selected_project)) || []
    )
    |> assign(:tracker_configs, persistence().list_tracker_configs())
    |> assign(:workflow_form, workflow_form)
    |> WorkflowState.assign_validation(workflow_form)
    |> assign(:workflow_setup_required, workflow_setup_required)
    |> assign(
      :project_configuration_items,
      ProjectSettings.scoped_configuration_items(configuration_items, "Project")
    )
    |> assign(
      :workflow_configuration_items,
      ProjectSettings.scoped_configuration_items(configuration_items, "Workflow")
    )
    |> assign(
      :runtime_configuration_items,
      ProjectSettings.scoped_configuration_items(configuration_items, "Runtime")
    )
    |> assign(:runtime_workflow_source, runtime_source_summary(runtime))
    |> assign(:db_runtime_mismatch, db_runtime_mismatch?(active, runtime))
    |> RunDetail.assign_data()
    |> IssueDetail.assign_data()
  end

  defp default_project do
    case persistence().default_project() do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp selected_project(%{assigns: %{route_params: params}}, projects, default_project) do
    case SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", "")) do
      nil ->
        default_project

      project_id ->
        Enum.find(projects, &(ProjectSettings.value(&1, :id) == project_id)) || default_project
    end
  end

  defp selected_project(_socket, _projects, default_project), do: default_project

  defp project_filter(%{assigns: %{route_params: params}}) do
    SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", ""))
  end

  defp runtime_source_summary({:ok, %{source: source}}), do: source_summary(source)

  defp source_summary(%{type: type} = source) do
    %{type: to_string(type), detail: source_detail(source)}
  end

  defp source_summary(_source), do: %{type: "unknown", detail: "n/a"}

  defp source_detail(%{type: :database, workflow_version_id: id}), do: id || "n/a"
  defp source_detail(%{type: :setup_required}), do: "setup required"
  defp source_detail(_source), do: "n/a"

  defp db_runtime_mismatch?(nil, _runtime), do: false

  defp db_runtime_mismatch?(version, {:ok, %{source: %{type: :database, workflow_version_id: id}}}) do
    version.id != id
  end

  defp db_runtime_mismatch?(_version, _runtime), do: true

  defp persistence, do: PersistenceProvider.module()
end
