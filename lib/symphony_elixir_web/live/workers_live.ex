defmodule SymphonyElixirWeb.WorkersLive do
  @moduledoc """
  Worker registry and worker-backed task queue page.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, PersistenceProvider}
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> assign(:route_params, params) |> refresh()}
  end

  @impl true
  def handle_event("cancel_task", %{"id" => id}, socket) do
    socket =
      case persistence().cancel_task(id) do
        {:ok, _task} -> socket |> put_flash(:info, "Task cancelled") |> refresh()
        {:error, reason} -> put_flash(socket, :error, "Task cancellation failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("requeue_task", %{"id" => id}, socket) do
    socket =
      case persistence().requeue_task(id) do
        {:ok, _task} -> socket |> put_flash(:info, "Task requeued") |> refresh()
        {:error, reason} -> put_flash(socket, :error, "Task requeue failed: #{inspect(reason)}")
      end

    {:noreply, socket}
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
              <p class="metric-detail">Panel-owned dispatch starts Codex without queueing HTTP worker-backed tasks.</p>
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
          <h2 class="section-title">Tasks</h2>
          <SymphonyElixirWeb.Layouts.project_switcher projects={@projects} current={@project_filter} base_path="/workers" />
        </div>
        <%= if @tasks == [] do %>
          <p class="empty-state">No worker-backed tasks have been queued yet.</p>
        <% else %>
          <table class="data-table">
            <thead><tr><th>Issue</th><th>Status</th><th>Validation</th><th>Source / runtime</th><th>Handoff</th><th>Queued</th><th></th></tr></thead>
            <tbody>
              <tr :for={task <- @tasks}>
                <td class="issue-id"><%= task.issue_identifier || "n/a" %></td>
                <td><span class={status_class(task.status)}><%= task.status %></span></td>
                <td><%= summary_value(task, "validation_status") %><%= gate_statuses(task) %></td>
                <td class="mono"><%= source_runtime(task) %></td>
                <td class="mono"><%= task_handoff(task) %></td>
                <td class="mono"><%= fmt_dt(task.queued_at) %></td>
                <td>
                  <button :if={task.status in ["queued", "leased", "running"]} class="subtle-button" phx-click="cancel_task" phx-value-id={task.id}>Cancel</button>
                  <button :if={task.status in ["failed", "cancelled", "expired"]} class="subtle-button" phx-click="requeue_task" phx-value-id={task.id}>Requeue</button>
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
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
    |> assign(:tasks, persistence().list_tasks(limit: 100, project_id: filter))
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
  defp worker_empty_message(mode), do: ObservabilityPresenter.worker_empty_message(mode)
  defp fmt_dt(value), do: ObservabilityPresenter.fmt_dt(value)
  defp labels_text(labels), do: ObservabilityPresenter.labels_text(labels)
  defp status_class(status), do: ObservabilityPresenter.status_class(status)

  defp summary_value(task, key), do: execution_summary(task)[key] || "n/a"

  defp gate_statuses(task) do
    case get_in(execution_summary(task), ["gates"]) do
      gates when is_list(gates) and gates != [] -> " (" <> Enum.map_join(gates, ", ", &"#{&1["name"]}: #{&1["status"]}") <> ")"
      _ -> ""
    end
  end

  defp source_runtime(task) do
    summary = execution_summary(task)
    runtime = summary["runtime"] || %{}

    Enum.join(
      Enum.reject(
        [summary["source_revision"], runtime["image_digest"] || runtime["image_tag"], runtime["worker_source_revision"]],
        &is_nil/1
      ),
      " | "
    )
  end

  defp task_handoff(task) do
    handoff = execution_summary(task)["handoff"] || %{}

    Enum.join(
      Enum.reject(
        [handoff["branch"], handoff["commit"], handoff["pr_identifier"], handoff["pr_url"], handoff["linear_state"]],
        &is_nil/1
      ),
      " | "
    )
  end

  defp execution_summary(task), do: Map.get(task, :execution_summary) || %{}
end
