defmodule SymphonyElixirWeb.AdminLive do
  @moduledoc """
  Operational pages for persisted Symphony projects, runs, workflows, and settings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Persistence, Workflow}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("save_raw_workflow", %{"workflow" => %{"raw" => raw}}, socket) do
    socket =
      case Persistence.default_project() do
        {:ok, project} ->
          case Persistence.import_workflow(project, raw, "web") do
            {:ok, _version} ->
              socket |> put_flash(:info, "Workflow saved") |> refresh()

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
      case version && Persistence.activate_workflow_version(version) do
        {:ok, _version} -> socket |> put_flash(:info, "Workflow activated") |> refresh()
        _ -> put_flash(socket, :error, "Workflow version not found")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <nav class="section-card">
        <a class="issue-link" href="/">Dashboard</a>
        <a class="issue-link" href="/projects">Projects</a>
        <a class="issue-link" href="/runs">Runs</a>
        <a class="issue-link" href="/workflows">Workflows</a>
        <a class="issue-link" href="/settings">Settings</a>
      </nav>

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

        <% :workflows -> %>
          <section class="section-card">
            <h1 class="section-title">Workflows</h1>
            <form phx-submit="save_raw_workflow">
              <label class="metric-label" for="workflow_raw">Raw WORKFLOW.md</label>
              <textarea id="workflow_raw" name="workflow[raw]" rows="18" style="width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;"><%= @active_workflow_raw %></textarea>
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
            <pre class="code-panel"><%= inspect(@tracker_configs, pretty: true) %></pre>
          </section>
      <% end %>
    </section>
    """
  end

  defp refresh(socket) do
    active = Persistence.active_workflow_version()

    socket
    |> assign(:projects, Persistence.list_projects())
    |> assign(:runs, Persistence.list_runs(limit: 100))
    |> assign(:events, Persistence.list_events(limit: 100))
    |> assign(:workflow_versions, Persistence.list_workflow_versions())
    |> assign(:tracker_configs, Persistence.list_tracker_configs())
    |> assign(:active_workflow_raw, active_workflow_raw(active))
  end

  defp active_workflow_raw(nil) do
    case Workflow.load() do
      {:ok, workflow} -> Workflow.to_markdown(workflow.config, workflow.prompt)
      {:error, _reason} -> ""
    end
  end

  defp active_workflow_raw(version), do: Persistence.export_workflow(version)

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_), do: "n/a"
end
