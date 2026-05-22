defmodule SymphonyElixirWeb.WorkersLive do
  @moduledoc """
  Worker registry and worker-backed task queue page.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, PersistenceProvider}
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
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
        <h2 class="section-title">Tasks</h2>
        <%= if @tasks == [] do %>
          <p class="empty-state">No worker-backed tasks have been queued yet.</p>
        <% else %>
          <table class="data-table">
            <thead><tr><th>Issue</th><th>Status</th><th>Mode</th><th>Queued</th><th></th></tr></thead>
            <tbody>
              <tr :for={task <- @tasks}>
                <td class="issue-id"><%= task.issue_identifier || "n/a" %></td>
                <td><span class={status_class(task.status)}><%= task.status %></span></td>
                <td><%= task.execution_mode %></td>
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
    socket
    |> assign(:workers, persistence().list_workers(limit: 100))
    |> assign(:tasks, persistence().list_tasks(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
  end

  defp persistence, do: PersistenceProvider.module()
  defp worker_empty_message(mode), do: ObservabilityPresenter.worker_empty_message(mode)
  defp fmt_dt(value), do: ObservabilityPresenter.fmt_dt(value)
  defp labels_text(labels), do: ObservabilityPresenter.labels_text(labels)
  defp status_class(status), do: ObservabilityPresenter.status_class(status)
end
