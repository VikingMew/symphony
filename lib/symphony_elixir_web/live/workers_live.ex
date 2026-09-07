defmodule SymphonyElixirWeb.WorkersLive do
  @moduledoc """
  Worker registry, current assignment, and worker execution history.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, PersistenceProvider}
  alias SymphonyElixir.Worker.AssignmentManager
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> assign(:route_params, params) |> refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={:workers} />

      <section :if={@projects_error} class="error-card" role="status">
        <h2 class="error-title">Data unavailable</h2>
        <p class="error-copy">Persisted project data could not be loaded. Please retry after database access is restored.</p>
      </section>

      <%= if @execution_mode == :centralized do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h1 class="section-title">Worker mode inactive</h1>
              <p class="section-copy">
                Execution mode is <span class="status-badge status-info">centralized</span>. Issues are dispatched directly by the panel; Codex runs locally unless centralized SSH worker hosts are configured.
              </p>
            </div>
          </div>
          <div class="metric-grid worker-mode-grid">
            <article class="metric-card">
              <p class="metric-label">Current path</p>
              <p class="metric-detail">Panel-owned dispatch starts Codex directly.</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Worker-backed mode</p>
              <p class="metric-detail">Set <span class="mono">SYMPHONY_EXECUTION_MODE=worker</span>, configure the worker API token/protocol, then run compatible external workers.</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Registered workers</p>
              <p class="metric-value numeric"><%= length(@workers) %></p>
              <p class="metric-detail">Historical registrations are shown below as inactive context in centralized mode.</p>
            </article>
          </div>
        </section>
      <% end %>

      <section class="section-card">
        <h1 class="section-title">Workers</h1>
        <p class="metric-label">Execution mode: <span class="status-badge status-info"><%= @execution_mode %></span></p>
        <%= if @workers == [] do %>
          <p class="empty-state"><%= worker_empty_message(@execution_mode) %></p>
        <% else %>
          <table class="data-table">
            <thead><tr><th>Name</th><th>Status</th><th>Labels</th><th>Last Seen</th></tr></thead>
            <tbody>
              <tr :for={worker <- @workers}>
                <td><%= worker.name %></td>
                <td><span class={status_class(worker.status)}><%= worker.status %></span></td>
                <td class="mono"><%= labels_text(worker.labels) %></td>
                <td class="mono"><%= fmt_dt(worker.last_seen_at) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <h2 class="section-title">Current assignment</h2>
          <SymphonyElixirWeb.Layouts.project_switcher projects={@projects} current={@project_filter} base_path="/workers" />
        </div>
        <%= if is_nil(@assignment) do %>
          <p class="empty-state">No in-memory worker assignment is active.</p>
        <% else %>
          <table class="data-table">
            <thead><tr><th>Issue</th><th>Assignment</th><th>Run</th><th>Session</th><th>Expires</th></tr></thead>
            <tbody>
              <tr>
                <td class="issue-id"><%= @assignment.issue_identifier %></td>
                <td class="mono"><%= @assignment.id %></td>
                <td class="mono"><%= @assignment.run_id %></td>
                <td class="mono"><%= @assignment.session_id %></td>
                <td class="mono"><%= fmt_dt(@assignment.expires_at) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </section>

      <section class="section-card">
        <h2 class="section-title">Worker run history</h2>
        <p :if={@runs == []} class="empty-state">No worker execution runs recorded.</p>
        <table :if={@runs != []} class="data-table">
          <thead><tr><th>Issue</th><th>Status</th><th>Run</th><th>Started</th><th>Finished</th></tr></thead>
          <tbody><tr :for={run <- @runs}><td><%= run.issue_identifier %></td><td><%= run.status %></td><td class="mono"><%= run.id %></td><td><%= fmt_dt(run.started_at) %></td><td><%= fmt_dt(run.finished_at) %></td></tr></tbody>
        </table>
      </section>
    </section>
    """
  end

  defp refresh(socket) do
    filter = project_filter(socket)
    {projects, projects_error} = read_projects()

    socket
    |> assign(:workers, persistence().list_workers(limit: 100))
    |> assign(:projects, projects)
    |> assign(:projects_error, projects_error)
    |> assign(:project_filter, filter)
    |> assign(:assignment, AssignmentManager.current_assignment())
    |> assign(:runs, worker_runs(filter))
    |> assign(:execution_mode, Config.execution_mode())
  end

  defp read_projects do
    case PersistenceProvider.read(fn -> persistence().list_projects() end) do
      projects when is_list(projects) -> {projects, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp project_filter(%{assigns: %{route_params: params}}) do
    SymphonyElixir.Text.blank_as_nil(Map.get(params, "project", ""))
  end

  defp persistence, do: PersistenceProvider.module()

  defp worker_runs(project_id) do
    case persistence().list_runs(limit: 100, project_id: project_id) do
      runs when is_list(runs) -> Enum.filter(runs, &(&1.execution_mode == "worker"))
      _error -> []
    end
  end

  defp worker_empty_message(mode), do: ObservabilityPresenter.worker_empty_message(mode)
  defp fmt_dt(value), do: ObservabilityPresenter.fmt_dt(value)
  defp labels_text(labels), do: ObservabilityPresenter.labels_text(labels)
  defp status_class(status), do: ObservabilityPresenter.status_class(status)
end
