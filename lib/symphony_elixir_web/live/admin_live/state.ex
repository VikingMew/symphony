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
    selected_project = selected_project(socket, projects)

    socket =
      if is_nil(projects_error),
        do: normalize_project_selection(socket, projects, selected_project),
        else: socket

    {workflow, workflow_error} = current_workflow(selected_project)
    runtime = WorkflowStore.current_with_source()
    {loaded_workflow_form, workflow_setup_required} = WorkflowState.load_form(workflow, runtime)
    workflow_form = WorkflowState.refreshed_form(socket, loaded_workflow_form)
    persistence_error = projects_error || default_project_error || workflow_error

    configuration_items =
      ProjectSettings.configuration_missing_items(workflow_setup_required, selected_project)

    socket
    |> assign(:projects, projects)
    |> assign(:persistence_error, persistence_error)
    |> assign(:default_project, default_project)
    |> assign(:selected_project, selected_project)
    |> assign(:current_workflow, workflow)
    |> Runs.assign_page(reset: true)
    |> Events.assign_data()
    |> assign(:tasks, persistence().list_tasks(limit: 100, project_id: project_filter(socket)))
    |> assign(:task_leases, persistence().list_task_leases(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
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

  defp current_workflow(nil), do: {nil, nil}

  defp current_workflow(project) do
    case PersistenceProvider.read(fn -> persistence().current_workflow(project) end) do
      {:error, reason} -> {nil, reason}
      workflow -> {workflow, nil}
    end
  end

  defp selected_project(%{assigns: %{route_params: params}}, projects) do
    first_enabled_project = Enum.find(projects, &(ProjectSettings.value(&1, :enabled) == true))

    case SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", "")) do
      nil ->
        first_enabled_project

      project_id ->
        Enum.find(projects, &(ProjectSettings.value(&1, :id) == project_id)) || first_enabled_project
    end
  end

  defp selected_project(_socket, projects) do
    Enum.find(projects, &(ProjectSettings.value(&1, :enabled) == true))
  end

  defp normalize_project_selection(%{assigns: %{route_params: params}} = socket, projects, selected_project) do
    project_id = SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", ""))

    if project_id && Enum.all?(projects, &(ProjectSettings.value(&1, :id) != project_id)) do
      route_params =
        case selected_project do
          nil -> Map.delete(params, "project")
          project -> Map.put(params, "project", ProjectSettings.value(project, :id))
        end

      assign(socket, :route_params, route_params)
    else
      socket
    end
  end

  defp normalize_project_selection(socket, _projects, _selected_project), do: socket

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

  defp source_detail(%{type: :database}), do: "current workflow"
  defp source_detail(%{type: :setup_required}), do: "setup required"
  defp source_detail(_source), do: "n/a"

  defp persistence, do: PersistenceProvider.module()
end
