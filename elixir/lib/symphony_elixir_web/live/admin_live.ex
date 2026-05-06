defmodule SymphonyElixirWeb.AdminLive do
  @moduledoc """
  Operational pages for persisted Symphony projects, runs, workflows, and settings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, PersistenceProvider, Workflow, WorkflowStore}

  @starter_workflow """
  ---
  tracker:
    kind: memory
    active_states: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"]
    terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
  polling:
    interval_ms: 30000
  workspace:
    root: "/tmp/symphony-workspaces"
  agent:
    max_concurrent_agents: 1
    max_turns: 20
  codex:
    command: "codex app-server"
    thread_sandbox: "workspace-write"
  server:
    host: "127.0.0.1"
    port: 4000
  ---

  You are an agent for this repository.
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:workflow_diagnostics_notice, nil) |> refresh()}
  end

  @impl true
  def handle_event("save_raw_workflow", %{"workflow" => %{"raw" => raw}}, socket) do
    socket =
      case persistence().default_project() do
        {:ok, project} ->
          case persistence().import_workflow(project, raw, "web") do
            {:ok, _version} ->
              _ = WorkflowStore.force_reload()

              socket
              |> put_flash(:info, "Workflow saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
              |> assign(:workflow_diagnostics_notice, "Workflow saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
              |> refresh()

            {:error, reason} ->
              put_flash(socket, :error, "Workflow rejected: #{inspect(reason)}")
          end

        {:error, reason} ->
          put_flash(socket, :error, "Project unavailable: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("activate_workflow", %{"id" => id}, socket) do
    version =
      socket.assigns.workflow_versions
      |> Enum.find(&(&1.id == id))

    socket =
      case version && persistence().activate_workflow_version(version) do
        {:ok, _version} ->
          _ = WorkflowStore.force_reload()

          socket
          |> put_flash(:info, "Workflow activated. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> assign(:workflow_diagnostics_notice, "Workflow activated. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> refresh()

        _ ->
          put_flash(socket, :error, "Workflow version not found")
      end

    {:noreply, socket}
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
      <SymphonyElixirWeb.Layouts.app_nav current={@live_action} />

      <%= case @live_action do %>
        <% :projects -> %>
          <section class="section-card">
            <h1 class="section-title">Projects</h1>
            <%= if @projects == [] do %>
              <p class="empty-state">No projects have been persisted yet.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Name</th><th>Slug</th><th>Enabled</th></tr></thead>
                <tbody>
                  <tr :for={project <- @projects}>
                    <td><%= project.name %></td>
                    <td class="mono"><%= project.slug %></td>
                    <td><%= project.enabled %></td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

        <% :runs -> %>
          <section class="section-card">
            <h1 class="section-title">Runs</h1>
            <%= if @runs == [] do %>
              <p class="empty-state">No persisted runs yet.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Issue</th><th>Status</th><th>Attempt</th><th>Started</th><th>Finished</th></tr></thead>
                <tbody>
                  <tr :for={run <- @runs}>
                    <td class="issue-id"><%= run.issue_identifier %></td>
                    <td><%= run.status %></td>
                    <td><%= run.attempt %></td>
                    <td class="mono"><%= fmt_dt(run.started_at) %></td>
                    <td class="mono"><%= fmt_dt(run.finished_at) %></td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

        <% :workers -> %>
          <section class="section-card">
            <h1 class="section-title">Workers</h1>
            <p class="metric-label">Execution mode: <span class="status-badge status-info"><%= @execution_mode %></span></p>
            <%= if @workers == [] do %>
              <p class="empty-state">No workers are registered. Centralized execution remains supported and does not require workers.</p>
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

        <% :workflows -> %>
          <section class="section-card">
            <h1 class="section-title">Workflows</h1>
            <p class="metric-label">
              Runtime source:
              <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span>
              <span class="muted mono"><%= @runtime_workflow_source.detail %></span>
            </p>
            <%= if @db_runtime_mismatch do %>
              <p class="empty-state">A database workflow is active, but runtime is currently using a different source.</p>
            <% end %>
            <%= if @workflow_setup_required do %>
              <p class="empty-state">No active workflow is configured yet. Paste or edit a workflow below to create the first database-backed version.</p>
            <% end %>
            <%= if @workflow_diagnostics_notice do %>
              <p class="empty-state">
                <%= @workflow_diagnostics_notice %>
                <a class="issue-link" href="/diagnostics/linear">Open Linear diagnostics</a>
              </p>
            <% end %>
            <form phx-submit="save_raw_workflow">
              <label class="metric-label" for="workflow_raw">Raw WORKFLOW.md</label>
              <textarea id="workflow_raw" class="workflow-editor" name="workflow[raw]" rows="18"><%= @active_workflow_raw %></textarea>
              <button class="subtle-button" type="submit">Save workflow version</button>
            </form>
          </section>
          <section class="section-card">
            <h2 class="section-title">Version History</h2>
            <%= if @workflow_versions == [] do %>
              <p class="empty-state">No workflow versions yet.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Version</th><th>Source</th><th>Active</th><th>Created</th><th></th></tr></thead>
                <tbody>
                  <tr :for={version <- @workflow_versions}>
                    <td><%= version.version %></td>
                    <td><%= version.source %></td>
                    <td><%= version.active %></td>
                    <td class="mono"><%= fmt_dt(version.inserted_at) %></td>
                    <td>
                      <button :if={!version.active} class="subtle-button" phx-click="activate_workflow" phx-value-id={version.id}>Activate</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

        <% :settings -> %>
          <section class="section-card">
            <h1 class="section-title">Settings</h1>
            <p class="metric-label">Execution mode: <span class="status-badge status-info"><%= @execution_mode %></span></p>
            <pre class="code-panel"><%= inspect(@tracker_configs, pretty: true) %></pre>
          </section>
      <% end %>
    </section>
    """
  end

  defp refresh(socket) do
    active = persistence().active_workflow_version()
    runtime = runtime_workflow()
    {active_workflow_raw, workflow_setup_required} = active_workflow_raw(active, runtime)

    socket
    |> assign(:projects, persistence().list_projects())
    |> assign(:runs, persistence().list_runs(limit: 100))
    |> assign(:events, persistence().list_events(limit: 100))
    |> assign(:workers, persistence().list_workers(limit: 100))
    |> assign(:worker_sessions, persistence().list_worker_sessions(limit: 100))
    |> assign(:tasks, persistence().list_tasks(limit: 100))
    |> assign(:task_leases, persistence().list_task_leases(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
    |> assign(:workflow_versions, persistence().list_workflow_versions())
    |> assign(:tracker_configs, persistence().list_tracker_configs())
    |> assign(:active_workflow_raw, active_workflow_raw)
    |> assign(:workflow_setup_required, workflow_setup_required)
    |> assign(:runtime_workflow_source, runtime_source_summary(runtime))
    |> assign(:db_runtime_mismatch, db_runtime_mismatch?(active, runtime))
  end

  defp active_workflow_raw(nil, {:ok, %{workflow: workflow}}) do
    if Map.get(workflow, :setup_required, false) do
      {@starter_workflow, true}
    else
      {Workflow.to_markdown(workflow.config, workflow.prompt), false}
    end
  end

  defp active_workflow_raw(nil, {:error, _reason}), do: {@starter_workflow, true}

  defp active_workflow_raw(version, _runtime), do: {persistence().export_workflow(version), false}

  defp persistence, do: PersistenceProvider.module()

  defp runtime_workflow do
    WorkflowStore.current_with_source()
  end

  defp runtime_source_summary({:ok, %{source: source}}), do: source_summary(source)
  defp runtime_source_summary({:error, reason}), do: %{type: "unavailable", detail: inspect(reason)}

  defp source_summary(%{type: type} = source), do: %{type: to_string(type), detail: source_detail(source)}
  defp source_summary(_source), do: %{type: "unknown", detail: "n/a"}

  defp source_detail(%{type: :file, path: path}), do: path
  defp source_detail(%{type: :database, workflow_version_id: id}), do: id || "n/a"
  defp source_detail(%{type: :setup_required}), do: "setup required"
  defp source_detail(_source), do: "n/a"

  defp db_runtime_mismatch?(nil, _runtime), do: false

  defp db_runtime_mismatch?(version, {:ok, %{source: %{type: :database, workflow_version_id: id}}}) do
    version.id != id
  end

  defp db_runtime_mismatch?(_version, _runtime), do: true

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_), do: "n/a"

  defp labels_text(%{"values" => labels}) when is_list(labels), do: Enum.join(labels, ", ")
  defp labels_text(_), do: ""

  defp status_class(status) when status in ["completed", "healthy", "online"], do: "status-badge status-success"
  defp status_class(status) when status in ["queued", "pending", "waiting"], do: "status-badge status-accent"
  defp status_class(status) when status in ["running", "retrying", "leased"], do: "status-badge status-warning"
  defp status_class(status) when status in ["failed", "offline", "expired"], do: "status-badge status-danger"
  defp status_class(_), do: "status-badge"
end
