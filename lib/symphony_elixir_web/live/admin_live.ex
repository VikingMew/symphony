defmodule SymphonyElixirWeb.AdminLive do
  @moduledoc """
  Operational pages for persisted Symphony projects, runs, workflows, and settings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.AdminLive.{
    Events,
    IssueDetail,
    RunDetail,
    Runs,
    SettingsShell,
    State,
    WorkflowState
  }

  alias SymphonyElixirWeb.AdminLive.Settings.{Import, Projects}

  @settings_actions [
    :settings,
    :settings_projects,
    :settings_workflow,
    :settings_agents,
    :settings_runtime,
    :settings_import
  ]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:linear_discovery, nil)
     |> assign(:linear_discovery_status, :idle)
     |> assign(:linear_discovery_message, nil)
     |> assign(:route_params, params)
     |> assign(:workflow_diagnostics_notice, nil)
     |> assign(:workflow_import_notice, nil)
     |> assign(:settings_import_yaml, "")
     |> assign(:settings_import_stage, nil)
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_field_errors, %{})
     |> assign(:workflow_check_targets, [])
     |> assign(:workflow_validation_error, nil)
     |> assign(:workflow_validation_visible?, false)
     |> assign(:workflow_form_valid?, false)
     |> assign(:workflow_form_dirty?, false)
     |> assign(:workflow_form_summary, %{})
     |> allow_upload(:settings_package,
       accept: :any,
       max_entries: 1,
       max_file_size: 128_000
     )
     |> State.refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:route_params, params)
     |> State.refresh()}
  end

  @impl true
  def handle_event("fetch_linear_discovery", _params, socket) do
    SettingsShell.fetch_linear_discovery(socket)
  end

  @impl true
  def handle_event("validate_workflow_form", %{"workflow" => params}, socket) do
    WorkflowState.validate(params, socket)
  end

  @impl true
  def handle_event("validate_settings_import_upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stage_settings_import", %{"import" => params}, socket) do
    Import.stage(params, socket)
  end

  @impl true
  def handle_event("confirm_settings_import", _params, socket) do
    Import.confirm(socket)
  end

  @impl true
  def handle_event("cancel_settings_import", _params, socket) do
    Import.cancel(socket)
  end

  @impl true
  def handle_event("save_workflow_form", %{"workflow" => params}, socket) do
    WorkflowState.save(params, socket)
  end

  @impl true
  def handle_event("save_project_settings", %{"project" => params}, socket) do
    Projects.save(params, socket)
  end

  @impl true
  def handle_event("restore_settings_version", %{"id" => id}, socket) do
    WorkflowState.restore(id, socket)
  end

  @impl true
  def handle_event("add_workflow_transition", _params, socket) do
    WorkflowState.add_transition(socket)
  end

  @impl true
  def handle_event("start_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.start_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening started: #{inspect(result)}")
     |> State.refresh()}
  end

  @impl true
  def handle_event("stop_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.stop_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening stopped: #{inspect(result)}")
     |> State.refresh()}
  end

  @impl true
  def handle_event("force_stop_all", _params, socket) do
    result = SymphonyElixir.Orchestrator.force_stop_all(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Force stop requested: #{inspect(result)}")
     |> State.refresh()}
  end

  @impl true
  def handle_event("load_more_runs", _params, socket) do
    {:noreply, Runs.assign_page(socket, reset: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={nav_current(@live_action)} />
      {page(@live_action, assigns)}
    </section>
    """
  end

  defp page(:runs, assigns), do: Runs.render(assigns)
  defp page(:run_detail, assigns), do: RunDetail.render(assigns)
  defp page(:issue_detail, assigns), do: IssueDetail.render(assigns)
  defp page(:events, assigns), do: Events.render(assigns)
  defp page(action, assigns) when action in @settings_actions, do: SettingsShell.render(assigns)

  defp nav_current(action) when action in @settings_actions, do: :settings
  defp nav_current(action), do: action

  defp orchestrator do
    SymphonyElixirWeb.Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end
end
