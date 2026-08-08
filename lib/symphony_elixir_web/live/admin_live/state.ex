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
    {projects, projects_error} = projects()
    {default_project, default_project_error} = default_project()
    selected_project = selected_project(socket, projects, default_project)
    {active, active_error} = active_workflow_version(selected_project)
    runtime = WorkflowStore.current_with_source()
    {loaded_workflow_form, workflow_setup_required} = WorkflowState.load_form(active, runtime)
    workflow_form = WorkflowState.refreshed_form(socket, loaded_workflow_form)
    persistence_error = projects_error || default_project_error || active_error

    configuration_items =
      ProjectSettings.configuration_missing_items(workflow_setup_required, default_project)

    socket
    |> assign(:projects, projects)
    |> assign(:persistence_error, persistence_error)
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

  defp projects do
    case PersistenceProvider.read(fn -> persistence().list_projects() end) do
      projects when is_list(projects) -> {projects, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp default_project do
    case PersistenceProvider.read(fn -> persistence().default_project() end) do
      {:ok, project} -> {project, nil}
      {:error, :not_found} -> {nil, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp active_workflow_version(nil), do: {nil, nil}

  defp active_workflow_version(project) do
    case PersistenceProvider.read(fn -> persistence().active_workflow_version(project) end) do
      {:error, reason} -> {nil, reason}
      version -> {version, nil}
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
  defp runtime_source_summary({:error, :no_active_workflow}), do: %{type: "setup_required", detail: "setup required"}

  defp runtime_source_summary({:error, reason}) do
    %{type: "unavailable", detail: inspect(reason)}
  end

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
