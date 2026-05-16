defmodule SymphonyElixirWeb.AdminLive do
  @moduledoc """
  Operational pages for persisted Symphony projects, runs, workflows, and settings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Linear.Discovery, PersistenceProvider, WorkflowForm, WorkflowStore, WorkflowValidator}

  @workflow_settings_source "web_workflow_settings"
  @agent_settings_source "web_agent_settings"

  attr(:events, :list, required: true)

  @spec event_table(map()) :: Phoenix.LiveView.Rendered.t()
  def event_table(assigns) do
    ~H"""
    <%= if @events == [] do %>
      <p class="empty-state">No events recorded.</p>
    <% else %>
      <table class="data-table">
        <thead><tr><th>Time</th><th>Issue</th><th>Type</th><th>Payload</th></tr></thead>
        <tbody>
          <tr :for={event <- @events}>
            <td class="mono"><%= fmt_dt(event.occurred_at) %></td>
            <td><%= event.issue_identifier || "n/a" %></td>
            <td><span class="status-badge status-info"><%= event.event_type %></span></td>
            <td><pre class="inline-code-panel"><%= safe_event_payload(event.payload) %></pre></td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  attr(:active, :atom, required: true)

  @spec settings_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, [
        {:projects, "Projects", "/settings/projects"},
        {:workflow, "Workflow", "/settings/workflow"},
        {:agents, "Agents", "/settings/agents"},
        {:runtime, "Runtime", "/settings/runtime"}
      ])

    ~H"""
    <nav class="settings-tabs" aria-label="Settings sections">
      <a
        :for={{key, label, path} <- @tabs}
        class="settings-tab-link"
        href={path}
        aria-current={if key == @active, do: "page"}
      >
        {label}
      </a>
    </nav>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:linear_discovery, nil)
     |> assign(:linear_discovery_message, nil)
     |> assign(:route_params, params)
     |> assign(:workflow_diagnostics_notice, nil)
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_validation_error, nil)
     |> assign(:workflow_validation_visible?, false)
     |> assign(:workflow_form_valid?, false)
     |> assign(:workflow_form_summary, %{})
     |> refresh()}
  end

  @impl true
  def handle_event("fetch_linear_discovery", _params, socket) do
    case Discovery.fetch() do
      {:ok, discovery} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:ok, discovery})
         |> assign(:linear_discovery_message, "Linear configuration fetched at #{fmt_dt(discovery.fetched_at)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:error, reason})
         |> assign(:linear_discovery_message, "Linear configuration fetch failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("validate_workflow_form", %{"workflow" => params}, socket) do
    draft = workflow_draft(socket, params)

    {:noreply,
     socket
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_validation_visible?, true)
     |> assign(:workflow_form, draft)
     |> assign_workflow_validation(draft)}
  end

  @impl true
  def handle_event("save_workflow_form", %{"workflow" => params}, socket) do
    draft = workflow_draft(socket, params) |> apply_project_settings(socket.assigns.default_project)
    section = settings_tab(socket.assigns.live_action)

    socket =
      with {:ok, raw} <- WorkflowForm.to_raw(draft),
           {:ok, _validation} <- WorkflowValidator.validate_raw(raw, runtime?: false),
           {:ok, project} <- persistence().default_project(),
           {:ok, version} <- safe_import_workflow(project, raw, settings_source(section)) do
        _ = WorkflowStore.force_reload()

        socket
        |> put_flash(:info, "#{settings_section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign_save_notice(:success, "#{settings_section_label(section)} saved", "Version #{version.version} is active. Runtime workflow refreshed.")
        |> assign(:workflow_diagnostics_notice, "#{settings_section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign(:workflow_validation_error, nil)
        |> assign(:workflow_validation_visible?, false)
        |> refresh()
      else
        {:error, message} when is_binary(message) ->
          socket
          |> put_flash(:error, "Workflow rejected: #{message}")
          |> assign_save_notice(:error, "Workflow save failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_validation_error, message)
          |> assign(:workflow_form_valid?, false)

        {:error, {:workflow_validation_failed, message}} ->
          socket
          |> put_flash(:error, "Workflow rejected: #{message}")
          |> assign_save_notice(:error, "Workflow save failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_validation_error, message)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_valid?, false)

        {:error, reason} ->
          message = inspect(reason)

          socket
          |> put_flash(:error, "Workflow rejected: #{message}")
          |> assign_save_notice(:error, "Workflow save failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_project_settings", %{"project" => params}, socket) do
    id = blank_as_nil(Map.get(params, "id"))
    attrs = project_attrs(params)

    result =
      case id do
        nil -> persistence().create_project(attrs)
        id -> persistence().update_project(id, attrs)
      end

    socket =
      case result do
        {:ok, project} ->
          socket
          |> put_flash(:info, "Project settings saved.")
          |> assign_save_notice(:success, "Project settings saved", "#{project.name} is available in Settings.")
          |> refresh()

        {:error, reason} ->
          message = changeset_or_reason(reason)

          socket
          |> put_flash(:error, "Project settings rejected: #{message}")
          |> assign_save_notice(:error, "Project settings failed", message)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("restore_settings_version", %{"id" => id}, socket) do
    section = settings_tab(socket.assigns.live_action)
    version = Enum.find(section_versions(socket.assigns.workflow_versions, section), &(&1.id == id))

    socket =
      with %{} = version <- version,
           raw when is_binary(raw) <- persistence().export_workflow(version),
           {:ok, history_draft} <- WorkflowForm.from_raw(raw),
           draft <- restore_settings_section(section, socket.assigns.workflow_form, history_draft),
           draft <- apply_project_settings(draft, socket.assigns.default_project),
           {:ok, restored_raw} <- WorkflowForm.to_raw(draft),
           {:ok, _validation} <- WorkflowValidator.validate_raw(restored_raw, runtime?: false),
           {:ok, project} <- persistence().default_project(),
           {:ok, restored_version} <- safe_import_workflow(project, restored_raw, settings_source(section)) do
        _ = WorkflowStore.force_reload()

        socket
        |> put_flash(:info, "#{settings_section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign_save_notice(:success, "#{settings_section_label(section)} restored", "Version #{restored_version.version} is active. Runtime workflow refreshed.")
        |> assign(:workflow_diagnostics_notice, "#{settings_section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign(:workflow_validation_error, nil)
        |> assign(:workflow_validation_visible?, false)
        |> refresh()
      else
        nil ->
          put_flash(socket, :error, "Settings version not found")

        {:error, {:workflow_validation_failed, message}} ->
          socket
          |> put_flash(:error, "Settings restore rejected: #{message}")
          |> assign_save_notice(:error, "Settings restore failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_validation_error, message)

        {:error, message} when is_binary(message) ->
          socket
          |> put_flash(:error, "Settings restore rejected: #{message}")
          |> assign_save_notice(:error, "Settings restore failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_validation_error, message)

        {:error, reason} ->
          message = inspect(reason)

          socket
          |> put_flash(:error, "Settings restore rejected: #{message}")
          |> assign_save_notice(:error, "Settings restore failed", message)
          |> assign(:workflow_validation_visible?, true)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_workflow_transition", _params, socket) do
    draft =
      socket.assigns
      |> Map.get(:workflow_form, %{})
      |> append_empty_transition()

    {:noreply,
     socket
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_validation_visible?, true)
     |> assign(:workflow_form, draft)
     |> assign_workflow_validation(draft)}
  end

  @impl true
  def handle_event("cancel_task", %{"id" => id}, socket) do
    socket =
      case persistence().cancel_task(id) do
        {:ok, _task} ->
          socket |> put_flash(:info, "Task cancelled") |> refresh()

        {:error, reason} ->
          put_flash(socket, :error, "Task cancellation failed: #{inspect(reason)}")
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
  def handle_event("start_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.start_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening started: #{inspect(result)}")
     |> refresh()}
  end

  @impl true
  def handle_event("stop_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.stop_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening stopped: #{inspect(result)}")
     |> refresh()}
  end

  @impl true
  def handle_event("force_stop_all", _params, socket) do
    result = SymphonyElixir.Orchestrator.force_stop_all(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Force stop requested: #{inspect(result)}")
     |> refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={nav_current(@live_action)} />

      <%= case @live_action do %>
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
                    <td class="issue-id">
                      <a class="issue-link" href={"/runs/#{run.id}"}><%= run.issue_identifier %></a>
                      <a class="issue-link" href={"/issues/#{run.issue_identifier}"}>Issue</a>
                    </td>
                    <td><%= run.status %></td>
                    <td><%= run.attempt %></td>
                    <td class="mono"><%= fmt_dt(run.started_at) %></td>
                    <td class="mono"><%= fmt_dt(run.finished_at) %></td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

        <% :run_detail -> %>
          <section class="section-card">
            <h1 class="section-title">Run Detail</h1>
            <%= if @run_detail.run do %>
              <table class="data-table">
                <tbody>
                  <tr><th>Issue</th><td><a class="issue-link" href={"/issues/#{@run_detail.run.issue_identifier}"}><%= @run_detail.run.issue_identifier %></a></td></tr>
                  <tr><th>Status</th><td><%= @run_detail.run.status %></td></tr>
                  <tr><th>Attempt</th><td><%= @run_detail.run.attempt %></td></tr>
                  <tr><th>Workspace</th><td class="mono"><%= @run_detail.run.workspace_path || "n/a" %></td></tr>
                  <tr><th>Started</th><td class="mono"><%= fmt_dt(@run_detail.run.started_at) %></td></tr>
                  <tr><th>Finished</th><td class="mono"><%= fmt_dt(@run_detail.run.finished_at) %></td></tr>
                  <tr><th>Failure</th><td><%= @run_detail.run.failure_reason || "n/a" %></td></tr>
                </tbody>
              </table>

              <h2 class="section-title">Workflow Version</h2>
              <%= if @run_detail.workflow_version do %>
                <pre class="code-panel"><%= workflow_version_summary(@run_detail.workflow_version) %></pre>
              <% else %>
                <p class="empty-state">No workflow version is attached to this run.</p>
              <% end %>

              <h2 class="section-title">Agent Turns</h2>
              <%= if @run_detail.turns == [] do %>
                <p class="empty-state">No agent turns recorded.</p>
              <% else %>
                <table class="data-table">
                  <thead><tr><th>Turn</th><th>Status</th><th>Started</th><th>Finished</th><th>Summary</th></tr></thead>
                  <tbody>
                    <tr :for={turn <- @run_detail.turns}>
                      <td><%= turn.turn_index %></td>
                      <td><%= turn.status %></td>
                      <td class="mono"><%= fmt_dt(turn.started_at) %></td>
                      <td class="mono"><%= fmt_dt(turn.finished_at) %></td>
                      <td><%= turn.summary || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              <% end %>

              <h2 class="section-title">Events</h2>
              <.event_table events={@run_detail.events} />
            <% else %>
              <p class="empty-state">Run not found.</p>
            <% end %>
          </section>

        <% :issue_detail -> %>
          <section class="section-card">
            <h1 class="section-title">Issue Detail</h1>
            <%= if @issue_detail.issue do %>
              <pre class="code-panel"><%= inspect(@issue_detail.issue, pretty: true) %></pre>
            <% else %>
              <p class="empty-state">No persisted issue snapshot found for <span class="mono"><%= @route_params["identifier"] %></span>.</p>
            <% end %>

            <h2 class="section-title">Runs</h2>
            <%= if @issue_detail.runs == [] do %>
              <p class="empty-state">No persisted runs for this issue.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Run</th><th>Status</th><th>Started</th><th>Finished</th></tr></thead>
                <tbody>
                  <tr :for={run <- @issue_detail.runs}>
                    <td><a class="issue-link" href={"/runs/#{run.id}"}><%= run.id %></a></td>
                    <td><%= run.status %></td>
                    <td class="mono"><%= fmt_dt(run.started_at) %></td>
                    <td class="mono"><%= fmt_dt(run.finished_at) %></td>
                  </tr>
                </tbody>
              </table>
            <% end %>

            <h2 class="section-title">Events</h2>
            <.event_table events={@issue_detail.events} />
          </section>

        <% :events -> %>
          <section class="section-card">
            <h1 class="section-title">Events</h1>
            <p class="section-copy">Persisted Symphony events. Payloads are bounded and scrubbed before display.</p>
            <form class="workflow-import-form" method="get" action="/events">
              <label><span class="metric-label">Issue</span><input name="issue_identifier" value={@event_filters.issue_identifier} /></label>
              <label><span class="metric-label">Run ID</span><input name="run_id" value={@event_filters.run_id} /></label>
              <label><span class="metric-label">Event type</span><input name="event_type" value={@event_filters.event_type} /></label>
              <label><span class="metric-label">Limit</span><input type="number" min="1" max="500" name="limit" value={@event_filters.limit} /></label>
              <button class="subtle-button" type="submit">Apply filters</button>
            </form>
            <.event_table events={@events} />
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

        <% action when action in [:settings, :settings_projects, :settings_workflow, :settings_agents, :settings_runtime] -> %>
          <section class="section-card settings-header-card">
            <h1 class="section-title">Settings</h1>
            <p class="metric-label">Configure workflow routing, agent profiles, and runtime settings.</p>
            <.settings_tabs active={settings_tab(action)} />
          </section>

          <%= case settings_tab(action) do %>
            <% :projects -> %>
          <section class="section-card settings-content-card">
            <h2 class="section-title">Projects</h2>
            <p class="metric-label">Each project owns its Linear project slug, repository URL, and default branch. Workflow and agent policy remain shared.</p>

            <section class="workflow-form-section">
              <div class="section-header">
                <div>
                  <h3>Linear Configuration Discovery</h3>
                  <p class="workflow-help-copy">Fetch read-only Linear projects, teams, and workflow states while filling project and workflow settings.</p>
                </div>
                <button type="button" class="subtle-button" phx-click="fetch_linear_discovery" phx-disable-with="Fetching...">Fetch Linear configuration</button>
              </div>

              <p :if={@linear_discovery_message} class="status-note"><%= @linear_discovery_message %></p>

              <%= case @linear_discovery do %>
                <% nil -> %>
                  <p class="empty-state">No Linear discovery data fetched yet.</p>
                <% {:error, reason} -> %>
                  <p class="error-copy"><strong>Discovery failed:</strong> <%= inspect(reason) %></p>
                <% {:ok, discovery} -> %>
                  <div class="metric-grid">
                    <article class="metric-card">
                      <span class="status-badge status-info">Account</span>
                      <p class="metric-label">Viewer</p>
                      <p class="metric-detail"><%= discovery.viewer.name %> <span class="mono"><%= discovery.viewer.email %></span></p>
                    </article>
                    <article class="metric-card">
                      <span class="status-badge status-info">Projects</span>
                      <p class="metric-label">Visible projects</p>
                      <p class="metric-detail"><%= length(discovery.projects) %></p>
                    </article>
                    <article class="metric-card">
                      <span class="status-badge status-info">Teams</span>
                      <p class="metric-label">Visible teams</p>
                      <p class="metric-detail"><%= length(discovery.teams) %></p>
                    </article>
                    <article class="metric-card">
                      <span class="status-badge status-info">States</span>
                      <p class="metric-label">State names</p>
                      <p class="metric-detail"><%= length(discovery.states) %></p>
                    </article>
                  </div>

                  <div class="diagnostics-grid">
                    <div>
                      <h3 class="diagnostics-subtitle">Linear Projects</h3>
                      <%= if discovery.projects == [] do %>
                        <p class="empty-state">No Linear projects returned.</p>
                      <% else %>
                        <div class="table-wrap">
                          <table class="data-table">
                            <thead>
                              <tr>
                                <th>Name</th>
                                <th>Slug</th>
                                <th>Teams</th>
                                <th>URL</th>
                                <th>Copy</th>
                              </tr>
                            </thead>
                            <tbody>
                              <tr :for={project <- discovery.projects}>
                                <td><%= project.name %></td>
                                <td class="mono"><%= project.slug %></td>
                                <td><%= project_team_names(project) %></td>
                                <td>
                                  <a :if={project.url != "n/a"} class="issue-link" href={project.url}>Open</a>
                                  <span :if={project.url == "n/a"} class="muted">n/a</span>
                                </td>
                                <td>
                                  <button type="button" class="subtle-button" data-label="Copy slug" data-copy={project.slug} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy slug</button>
                                </td>
                              </tr>
                            </tbody>
                          </table>
                        </div>
                      <% end %>
                    </div>

                    <div>
                      <h3 class="diagnostics-subtitle">Teams and States</h3>
                      <%= if discovery.teams == [] do %>
                        <p class="empty-state">No Linear teams returned.</p>
                      <% else %>
                        <div class="table-wrap">
                          <table class="data-table">
                            <thead>
                              <tr>
                                <th>Team</th>
                                <th>Key</th>
                                <th>States</th>
                                <th>Copy</th>
                              </tr>
                            </thead>
                            <tbody>
                              <tr :for={team <- discovery.teams}>
                                <td><%= team.name %></td>
                                <td class="mono"><%= team.key %></td>
                                <td><%= Enum.join(team.states, ", ") %></td>
                                <td>
                                  <button type="button" class="subtle-button" data-label="Copy states" data-copy={Enum.join(team.states, "\n")} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy states</button>
                                </td>
                              </tr>
                            </tbody>
                          </table>
                        </div>
                      <% end %>
                    </div>

                    <div>
                      <h3 class="diagnostics-subtitle">Suggested State Lists</h3>
                      <table class="data-table diagnostics-table">
                        <tbody>
                          <tr>
                            <th>Active states</th>
                            <td><%= Enum.join(discovery.suggestions.active_states, ", ") %></td>
                            <td><button type="button" class="subtle-button" data-label="Copy" data-copy={Enum.join(discovery.suggestions.active_states, "\n")} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy</button></td>
                          </tr>
                          <tr>
                            <th>Terminal states</th>
                            <td><%= Enum.join(discovery.suggestions.terminal_states, ", ") %></td>
                            <td><button type="button" class="subtle-button" data-label="Copy" data-copy={Enum.join(discovery.suggestions.terminal_states, "\n")} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy</button></td>
                          </tr>
                          <tr>
                            <th>Review states</th>
                            <td><%= Enum.join(discovery.suggestions.review_states, ", ") %></td>
                            <td><button type="button" class="subtle-button" data-label="Copy" data-copy={Enum.join(discovery.suggestions.review_states, "\n")} onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);">Copy</button></td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
              <% end %>
            </section>

            <%= if @workflow_save_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_save_notice.title %></strong>
                <span><%= @workflow_save_notice.message %></span>
              </aside>
            <% end %>

            <div class="workflow-profile-grid">
              <article :for={project <- @projects} class="workflow-profile-panel">
                <header class="workflow-profile-header">
                  <div>
                    <h4><%= project.name %></h4>
                    <p class="metric-label mono"><%= project.slug %></p>
                  </div>
                  <span class={if project.enabled, do: "status-badge status-info", else: "status-badge"}><%= if project.enabled, do: "enabled", else: "disabled" %></span>
                </header>

                <form class="workflow-form settings-editor-form project-edit-form" data-project-id={project.id} phx-submit="save_project_settings">
                  <input type="hidden" name="project[id]" value={project.id} />
                  <div class="workflow-profile-field-grid">
                    <label class="settings-field"><span class="metric-label">Name</span><input name="project[name]" value={project.name} /></label>
                    <label class="settings-field"><span class="metric-label">Internal slug</span><input name="project[slug]" value={project.slug} /></label>
                    <label class="settings-field"><span class="metric-label">Linear project slug</span><input name="project[linear_project_slug]" value={project_value(project, :linear_project_slug)} /></label>
                    <label class="settings-field"><span class="metric-label">Repository URL</span><input name="project[repository_url]" value={project_value(project, :repository_url)} /></label>
                    <label class="settings-field"><span class="metric-label">Default branch</span><input name="project[default_branch]" value={project_value(project, :default_branch) || "main"} /></label>
                    <label class="settings-field"><span class="metric-label">Description</span><input name="project[description]" value={project_value(project, :description)} /></label>
                    <div class="workflow-checkbox-row">
                      <input type="hidden" name="project[enabled]" value="false" />
                      <label><input type="checkbox" name="project[enabled]" value="true" checked={project.enabled} /> Enabled</label>
                    </div>
                  </div>
                  <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save project</button>
                </form>
              </article>
            </div>

            <section class="workflow-form-section">
              <h3>Add Project</h3>
              <form class="workflow-form settings-editor-form project-create-form" phx-submit="save_project_settings">
                <div class="workflow-profile-field-grid">
                  <label class="settings-field"><span class="metric-label">Name</span><input name="project[name]" /></label>
                  <label class="settings-field"><span class="metric-label">Internal slug</span><input name="project[slug]" /></label>
                  <label class="settings-field"><span class="metric-label">Linear project slug</span><input name="project[linear_project_slug]" /></label>
                  <label class="settings-field"><span class="metric-label">Repository URL</span><input name="project[repository_url]" /></label>
                  <label class="settings-field"><span class="metric-label">Default branch</span><input name="project[default_branch]" value="main" /></label>
                  <label class="settings-field"><span class="metric-label">Description</span><input name="project[description]" /></label>
                  <div class="workflow-checkbox-row">
                    <input type="hidden" name="project[enabled]" value="false" />
                    <label><input type="checkbox" name="project[enabled]" value="true" checked /> Enabled</label>
                  </div>
                </div>
                <button class="subtle-button" type="submit" phx-disable-with="Saving...">Add project</button>
              </form>
            </section>
          </section>

            <% :workflow -> %>
          <section class="section-card">
            <h2 class="section-title">Workflow</h2>
            <p class="metric-label">
              Runtime source:
              <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span>
              <span class="muted mono"><%= @runtime_workflow_source.detail %></span>
            </p>
            <%= if @db_runtime_mismatch do %>
              <p class="empty-state">A database workflow is active, but runtime is currently using a different source.</p>
            <% end %>
            <%= if @workflow_setup_required do %>
              <p class="empty-state">No active workflow is configured yet. Fill the structured draft below.</p>
            <% end %>
            <%= if @workflow_setup_missing_items != [] do %>
              <aside class="setup-guidance-card" role="status" aria-live="polite">
                <h3>Setup checklist</h3>
                <ul>
                  <li :for={item <- @workflow_setup_missing_items}>
                    <strong><%= item.title %></strong>
                    <span><%= item.detail %></span>
                    <a :if={item.href} class="issue-link" href={item.href}><%= item.action %></a>
                  </li>
                </ul>
              </aside>
            <% end %>
            <%= if @workflow_diagnostics_notice do %>
              <p class="empty-state">
                <%= @workflow_diagnostics_notice %>
                <a class="issue-link" href="/diagnostics/linear">Open Linear diagnostics</a>
              </p>
            <% end %>
            <%= if @workflow_validation_visible? && @workflow_validation_error do %>
              <p class="error-copy"><strong>Validation failed:</strong> <%= @workflow_validation_error %></p>
            <% end %>
            <%= if @workflow_save_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_save_notice.title %></strong>
                <span><%= @workflow_save_notice.message %></span>
              </aside>
            <% end %>

            <form class="workflow-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form">
              <div class="workflow-form-header">
                <div>
                  <h2 class="section-title">Draft Configuration</h2>
                  <p class="metric-label">Edit fields, review validation, then save a database workflow version.</p>
                </div>
                <button class="subtle-button" type="submit" disabled={!@workflow_form_valid?} phx-disable-with="Saving...">Save workflow version</button>
              </div>

              <div class="workflow-summary-grid">
                <p><span class="metric-label">Tracker</span><strong><%= @workflow_form_summary.tracker %></strong></p>
                <p><span class="metric-label">Project</span><strong><%= @workflow_form_summary.project %></strong></p>
                <p><span class="metric-label">Repository</span><strong><%= @workflow_form_summary.repository %></strong></p>
                <p><span class="metric-label">Hooks</span><strong><%= @workflow_form_summary.hooks %></strong></p>
                <p><span class="metric-label">Profiles</span><strong><%= @workflow_form_summary.profiles %></strong></p>
                <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
              </div>

              <div class="workflow-form-grid">
                <section class="workflow-form-section">
                  <h3>Tracker</h3>
                  <p class="metric-label">Linear tracker is managed by shared runtime configuration. Project-specific Linear slugs are configured in Settings / Projects.</p>
                  <label><span class="metric-label">Assignee</span><input name="workflow[tracker_assignee]" value={@workflow_form["tracker_assignee"]} /></label>
                  <label><span class="metric-label">Active states</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[active_states]" rows="5"><%= @workflow_form["active_states"] %></textarea></label>
                  <label><span class="metric-label">Terminal states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[terminal_states]" rows="4"><%= @workflow_form["terminal_states"] %></textarea></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Bootstrap</h3>
                  <p class="metric-label">Repository URL and default branch are configured per project in Settings / Projects.</p>
                  <label><span class="metric-label">Checkout depth</span><input type="number" min="1" name="workflow[project_checkout_depth]" value={@workflow_form["project_checkout_depth"]} /></label>
                  <label><span class="metric-label">Setup commands</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[project_setup_commands]" rows="5"><%= @workflow_form["project_setup_commands"] %></textarea></label>
                  <label><span class="metric-label">Cleanup commands</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[project_cleanup_commands]" rows="4"><%= @workflow_form["project_cleanup_commands"] %></textarea></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Lifecycle Hooks</h3>
                  <p class="workflow-help-copy">
                    Hooks execute shell commands in the issue workspace. Project checkout and setup run before after_create; cleared hook fields are removed from the saved workflow.
                  </p>
                  <label><span class="metric-label">Hook timeout ms</span><input type="number" min="1" name="workflow[hook_timeout_ms]" value={@workflow_form["hook_timeout_ms"]} /></label>
                  <label><span class="metric-label">after_create</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_create]" rows="4"><%= @workflow_form["hook_after_create"] %></textarea></label>
                  <label><span class="metric-label">before_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_run]" rows="3"><%= @workflow_form["hook_before_run"] %></textarea></label>
                  <label><span class="metric-label">after_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_run]" rows="3"><%= @workflow_form["hook_after_run"] %></textarea></label>
                  <label><span class="metric-label">before_remove</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_remove]" rows="3"><%= @workflow_form["hook_before_remove"] %></textarea></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Runtime</h3>
                  <label><span class="metric-label">Workspace root</span><input name="workflow[workspace_root]" value={@workflow_form["workspace_root"]} /></label>
                  <label><span class="metric-label">Polling interval ms</span><input type="number" min="1" name="workflow[polling_interval_ms]" value={@workflow_form["polling_interval_ms"]} /></label>
                  <label><span class="metric-label">Max agents</span><input type="number" min="1" name="workflow[agent_max_concurrent_agents]" value={@workflow_form["agent_max_concurrent_agents"]} /></label>
                  <label><span class="metric-label">Max turns</span><input type="number" min="1" name="workflow[agent_max_turns]" value={@workflow_form["agent_max_turns"]} /></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Codex</h3>
                  <label><span class="metric-label">Command</span><input name="workflow[codex_command]" value={@workflow_form["codex_command"]} /></label>
                  <label><span class="metric-label">Thread sandbox</span><input name="workflow[codex_thread_sandbox]" value={@workflow_form["codex_thread_sandbox"]} /></label>
                </section>
              </div>

              <section class="workflow-form-section">
                <h3>Workflow Phases / State Routing</h3>
                <div class="workflow-routing-grid">
                  <label :for={{state, attrs} <- workflow_state_entries(@workflow_form)}>
                    <span class="metric-label"><%= state %></span>
                    <select name={"workflow[workflow_states][#{state}][profile]"}>
                      <option value="">No profile</option>
                      <option :for={profile <- WorkflowForm.profile_options(@workflow_form)} value={profile} selected={attrs["profile"] == profile}><%= profile %></option>
                    </select>
                  </label>
                </div>
                <label><span class="metric-label">Human review states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[human_review_states]" rows="4"><%= @workflow_form["human_review_states"] %></textarea></label>
                <div>
                  <div class="workflow-subsection-heading">
                    <span class="metric-label">Allowed transitions</span>
                    <button
                      class="workflow-add-button"
                      type="button"
                      phx-click="add_workflow_transition"
                      title="Add transition"
                      aria-label="Add transition"
                    >+</button>
                  </div>
                  <div class="workflow-transition-grid">
                    <div class="workflow-transition-header">From</div>
                    <div class="workflow-transition-header">To</div>
                    <div class="workflow-transition-header">Actor</div>
                    <div class="workflow-transition-header">Profile</div>
                    <div :for={{transition, index} <- transition_entries(@workflow_form)} class="workflow-transition-row">
                      <input name={"workflow[allowed_transitions][#{index}][from]"} value={transition["from"]} />
                      <input name={"workflow[allowed_transitions][#{index}][to]"} value={transition["to"]} />
                      <select name={"workflow[allowed_transitions][#{index}][actor]"}>
                        <option value="">Select</option>
                        <option value="codex" selected={transition["actor"] == "codex"}>codex</option>
                        <option value="human" selected={transition["actor"] == "human"}>human</option>
                      </select>
                      <select name={"workflow[allowed_transitions][#{index}][profile]"}>
                        <option value="">No profile</option>
                        <option :for={profile <- WorkflowForm.profile_options(@workflow_form)} value={profile} selected={transition["profile"] == profile}><%= profile %></option>
                      </select>
                    </div>
                  </div>
                </div>
              </section>

            </form>
          </section>
          <section class="section-card">
            <h2 class="section-title">Version History</h2>
            <%= if section_versions(@workflow_versions, :workflow) == [] do %>
              <p class="empty-state">No workflow versions yet.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Version</th><th>Source</th><th>Active</th><th>Created</th><th></th></tr></thead>
                <tbody>
                  <tr :for={version <- section_versions(@workflow_versions, :workflow)}>
                    <td><%= version.version %></td>
                    <td><%= version.source %></td>
                    <td><%= version.active %></td>
                    <td class="mono"><%= fmt_dt(version.inserted_at) %></td>
                    <td>
                      <button class="subtle-button" phx-click="restore_settings_version" phx-value-id={version.id}>Restore workflow settings</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

            <% :agents -> %>
          <section class="section-card settings-content-card">
            <h2 class="section-title">Agents</h2>
            <p class="metric-label">
              Runtime source:
              <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span>
              <span class="muted mono"><%= @runtime_workflow_source.detail %></span>
            </p>
            <%= if @workflow_validation_visible? && @workflow_validation_error do %>
              <p class="error-copy"><strong>Validation failed:</strong> <%= @workflow_validation_error %></p>
            <% end %>
            <%= if @workflow_save_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_save_notice.title %></strong>
                <span><%= @workflow_save_notice.message %></span>
              </aside>
            <% end %>

            <form class="workflow-form settings-editor-form agent-settings-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form">
              <div class="workflow-form-header settings-action-row">
                <div>
                  <h2 class="section-title">Profile Configuration</h2>
                  <p class="metric-label">Edit agent execution profiles, prompt composition, update permissions, and target states.</p>
                </div>
                <button class="subtle-button" type="submit" disabled={!@workflow_form_valid?} phx-disable-with="Saving...">Save agent settings</button>
              </div>

              <div class="workflow-summary-grid">
                <p><span class="metric-label">Profiles</span><strong><%= @workflow_form_summary.profiles %></strong></p>
                <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
                <p><span class="metric-label">Prompt</span><strong><%= @workflow_form_summary.prompt_chars %> chars</strong></p>
              </div>

              <section class="workflow-form-section agent-prompt-editor">
                <div class="agent-section-heading">
                  <div>
                    <h3>Base Prompt</h3>
                    <p class="workflow-help-copy">Shared task template used by profile prompts unless a profile replaces it.</p>
                  </div>
                  <span class="status-badge status-info">shared</span>
                </div>
                <div class="agent-field agent-field-full">
                  <label class="agent-field-label" for="workflow-prompt-body">Base prompt</label>
                  <textarea id="workflow-prompt-body" class="workflow-textbox workflow-textbox-prompt" name="workflow[prompt_body]" rows="12"><%= @workflow_form["prompt_body"] %></textarea>
                </div>
              </section>

              <section class="workflow-form-section agent-profiles-section">
                <div class="agent-section-heading">
                  <div>
                    <h3>Profiles</h3>
                    <p class="workflow-help-copy">Each profile defines one stage-specific agent policy.</p>
                  </div>
                </div>
                <div class="workflow-profile-grid">
                  <article :for={{profile_id, profile} <- profile_entries(@workflow_form)} class="workflow-profile-panel">
                    <header class="workflow-profile-header">
                      <div>
                        <h4><%= profile["name"] || profile_id %></h4>
                        <p class="metric-label mono"><%= profile_id %></p>
                      </div>
                      <div class="workflow-profile-badges">
                        <span class="status-badge status-info"><%= profile["executor_type"] %></span>
                        <span class="status-badge"><%= profile["prompt_mode"] %></span>
                      </div>
                    </header>

                    <div class="workflow-profile-field-grid">
                      <section class="profile-field-group">
                        <h5>Identity</h5>
                        <div class="agent-field">
                          <label class="agent-field-label" for={"profile-#{profile_id}-name"}>Name</label>
                          <input id={"profile-#{profile_id}-name"} name={"workflow[profiles][#{profile_id}][name]"} value={profile["name"]} />
                        </div>
                      </section>

                      <section class="profile-field-group">
                        <h5>Execution</h5>
                        <div class="agent-field">
                          <label class="agent-field-label" for={"profile-#{profile_id}-executor"}>Executor</label>
                          <select id={"profile-#{profile_id}-executor"} name={"workflow[profiles][#{profile_id}][executor_type]"}>
                            <option value="codex_agent" selected={profile["executor_type"] == "codex_agent"}>codex_agent</option>
                            <option value="backend_action" selected={profile["executor_type"] == "backend_action"}>backend_action</option>
                            <option value="manual" selected={profile["executor_type"] == "manual"}>manual</option>
                            <option value="external_worker" selected={profile["executor_type"] == "external_worker"}>external_worker</option>
                          </select>
                        </div>
                      </section>

                      <section class="profile-field-group profile-field-group-prompt">
                        <h5>Prompt</h5>
                        <div class="profile-prompt-layout">
                          <div class="agent-field profile-prompt-mode-field">
                            <label class="agent-field-label" for={"profile-#{profile_id}-prompt-mode"}>Prompt mode</label>
                            <select id={"profile-#{profile_id}-prompt-mode"} name={"workflow[profiles][#{profile_id}][prompt_mode]"}>
                              <option value="extend" selected={profile["prompt_mode"] == "extend"}>extend</option>
                              <option value="replace" selected={profile["prompt_mode"] == "replace"}>replace</option>
                              <option value="disabled" selected={profile["prompt_mode"] == "disabled"}>disabled</option>
                            </select>
                          </div>
                          <div class="agent-field agent-field-full">
                            <label class="agent-field-label" for={"profile-#{profile_id}-prompt-template"}>Profile prompt template</label>
                            <textarea id={"profile-#{profile_id}-prompt-template"} class="workflow-textbox workflow-textbox-profile" name={"workflow[profiles][#{profile_id}][prompt_template]"} rows="5"><%= profile["prompt_template"] %></textarea>
                          </div>
                        </div>
                      </section>

                      <section class="profile-field-group">
                        <h5>Updates</h5>
                        <div class="workflow-checkbox-row">
                          <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_description]"} value="false" />
                          <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_description]"} value="true" checked={profile["allow_description"] == "true"} /> Description</label>
                          <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_comment]"} value="false" />
                          <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_comment]"} value="true" checked={profile["allow_comment"] == "true"} /> Comment</label>
                          <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_result]"} value="false" />
                          <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_result]"} value="true" checked={profile["allow_result"] == "true"} /> Result</label>
                        </div>
                      </section>

                      <section class="profile-field-group">
                        <h5>Routing</h5>
                        <div class="agent-field">
                          <label class="agent-field-label" for={"profile-#{profile_id}-target-states"}>Allowed target states</label>
                          <textarea id={"profile-#{profile_id}-target-states"} class="workflow-textbox workflow-textbox-compact" name={"workflow[profiles][#{profile_id}][target_states]"} rows="4"><%= profile["target_states"] %></textarea>
                        </div>
                      </section>
                    </div>
                  </article>
                </div>
              </section>
            </form>
          </section>
          <section class="section-card">
            <h2 class="section-title">Version History</h2>
            <%= if section_versions(@workflow_versions, :agents) == [] do %>
              <p class="empty-state">No agent settings versions yet.</p>
            <% else %>
              <table class="data-table">
                <thead><tr><th>Version</th><th>Source</th><th>Active</th><th>Created</th><th></th></tr></thead>
                <tbody>
                  <tr :for={version <- section_versions(@workflow_versions, :agents)}>
                    <td><%= version.version %></td>
                    <td><%= version.source %></td>
                    <td><%= version.active %></td>
                    <td class="mono"><%= fmt_dt(version.inserted_at) %></td>
                    <td>
                      <button class="subtle-button" phx-click="restore_settings_version" phx-value-id={version.id}>Restore agent settings</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

            <% :runtime -> %>
          <section class="section-card">
            <h2 class="section-title">Runtime</h2>
            <p class="metric-label">Execution mode: <span class="status-badge status-info"><%= @execution_mode %></span></p>
            <pre class="code-panel"><%= inspect(@tracker_configs, pretty: true) %></pre>
          </section>
          <% end %>
      <% end %>
    </section>
    """
  end

  defp refresh(socket) do
    active = persistence().active_workflow_version()
    runtime = runtime_workflow()
    {workflow_form, workflow_setup_required} = workflow_form(active, runtime)
    default_project = default_project()

    socket
    |> assign(:projects, persistence().list_projects())
    |> assign(:default_project, default_project)
    |> assign(:runs, persistence().list_runs(limit: 100))
    |> assign(:events, event_list(socket))
    |> assign(:event_filters, event_filters(socket))
    |> assign(:workers, persistence().list_workers(limit: 100))
    |> assign(:worker_sessions, persistence().list_worker_sessions(limit: 100))
    |> assign(:tasks, persistence().list_tasks(limit: 100))
    |> assign(:task_leases, persistence().list_task_leases(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
    |> assign(:workflow_versions, persistence().list_workflow_versions())
    |> assign(:tracker_configs, persistence().list_tracker_configs())
    |> assign(:workflow_form, workflow_form)
    |> assign_workflow_validation(workflow_form)
    |> assign(:workflow_setup_required, workflow_setup_required)
    |> assign(:workflow_setup_missing_items, workflow_setup_missing_items(workflow_setup_required, default_project))
    |> assign(:runtime_workflow_source, runtime_source_summary(runtime))
    |> assign(:db_runtime_mismatch, db_runtime_mismatch?(active, runtime))
    |> assign_detail_data()
  end

  defp nav_current(action) when action in [:settings, :settings_projects, :settings_workflow, :settings_agents, :settings_runtime], do: :settings
  defp nav_current(action), do: action

  defp settings_tab(:settings), do: :projects
  defp settings_tab(:settings_projects), do: :projects
  defp settings_tab(:settings_workflow), do: :workflow
  defp settings_tab(:settings_agents), do: :agents
  defp settings_tab(:settings_runtime), do: :runtime

  defp default_project do
    case persistence().default_project() do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp workflow_setup_missing_items(workflow_setup_required, project) do
    []
    |> maybe_add_workflow_version_item(workflow_setup_required)
    |> maybe_add_project_item(project, :linear_project_slug, "Linear project slug", "Set the Linear project slug on the default project.", "Edit projects")
    |> maybe_add_project_item(project, :repository_url, "Repository URL", "Set the repository URL on the default project so runs can create workspaces.", "Edit projects")
    |> maybe_add_linear_api_token_item()
  end

  defp maybe_add_workflow_version_item(items, true) do
    items ++
      [
        %{
          title: "Workflow version",
          detail: "Save the draft below to create the first active workflow version.",
          href: nil,
          action: nil
        }
      ]
  end

  defp maybe_add_workflow_version_item(items, _workflow_setup_required), do: items

  defp maybe_add_project_item(items, nil, _key, title, detail, action) do
    items ++ [%{title: title, detail: detail, href: "/settings/projects", action: action}]
  end

  defp maybe_add_project_item(items, project, key, title, detail, action) do
    if blank?(project_value(project, key)) do
      items ++ [%{title: title, detail: detail, href: "/settings/projects", action: action}]
    else
      items
    end
  end

  defp maybe_add_linear_api_token_item(items) do
    if blank?(System.get_env("LINEAR_API_KEY")) do
      items ++
        [
          %{
            title: "Linear API token",
            detail: "Set LINEAR_API_KEY in the runtime environment before running Linear diagnostics or listening.",
            href: nil,
            action: nil
          }
        ]
    else
      items
    end
  end

  defp settings_source(:agents), do: @agent_settings_source
  defp settings_source(_section), do: @workflow_settings_source

  defp settings_section_label(:agents), do: "Agent settings"
  defp settings_section_label(_section), do: "Workflow settings"

  defp section_versions(versions, section) do
    Enum.filter(versions, &(settings_version_section(&1) == section))
  end

  defp settings_version_section(version) do
    case Map.get(version, :source) || Map.get(version, "source") do
      @agent_settings_source -> :agents
      @workflow_settings_source -> :workflow
      _source -> nil
    end
  end

  defp event_list(socket) do
    filters = event_filters(socket)

    persistence().list_events(
      issue_identifier: blank_as_nil(filters.issue_identifier),
      run_id: blank_as_nil(filters.run_id),
      event_type: blank_as_nil(filters.event_type),
      limit: filters.limit
    )
  end

  defp event_filters(%{assigns: %{route_params: params}}) do
    %{
      issue_identifier: Map.get(params, "issue_identifier", ""),
      run_id: Map.get(params, "run_id", ""),
      event_type: Map.get(params, "event_type", ""),
      limit: parse_limit(Map.get(params, "limit", "100"))
    }
  end

  defp parse_limit(value) do
    case Integer.parse(to_string(value || "")) do
      {limit, ""} -> limit |> max(1) |> min(500)
      _ -> 100
    end
  end

  defp blank_as_nil(value) do
    value = String.trim(to_string(value || ""))
    if value == "", do: nil, else: value
  end

  defp blank?(value), do: is_nil(blank_as_nil(value))

  defp assign_detail_data(%{assigns: %{live_action: :run_detail, route_params: %{"id" => id}}} = socket) do
    run = persistence().get_run(id)

    workflow_version =
      case run && Map.get(run, :workflow_version_id) do
        id when is_binary(id) -> persistence().get_workflow_version(id)
        _ -> nil
      end

    assign(socket, :run_detail, %{
      run: run,
      workflow_version: workflow_version,
      turns: if(run, do: persistence().list_agent_turns_for_run(run.id), else: []),
      events: if(run, do: persistence().list_events(run_id: run.id, limit: 100), else: [])
    })
  end

  defp assign_detail_data(%{assigns: %{live_action: :issue_detail, route_params: %{"identifier" => identifier}}} = socket) do
    assign(socket, :issue_detail, %{
      issue: persistence().get_issue_by_identifier(identifier),
      runs: persistence().list_runs_for_issue(identifier, limit: 100),
      events: persistence().list_events(issue_identifier: identifier, limit: 100)
    })
  end

  defp assign_detail_data(socket) do
    socket
    |> assign_new(:run_detail, fn -> %{run: nil, workflow_version: nil, turns: [], events: []} end)
    |> assign_new(:issue_detail, fn -> %{issue: nil, runs: [], events: []} end)
  end

  defp workflow_form(nil, {:ok, %{workflow: workflow}}) do
    if Map.get(workflow, :setup_required, false) do
      {WorkflowForm.empty(), true}
    else
      {WorkflowForm.from_loaded(workflow), false}
    end
  end

  defp workflow_form(version, _runtime) do
    version
    |> persistence().export_workflow()
    |> WorkflowForm.from_raw()
    |> case do
      {:ok, draft} -> {draft, false}
      {:error, _reason} -> {WorkflowForm.empty(), false}
    end
  end

  defp workflow_draft(socket, params) do
    current = Map.get(socket.assigns, :workflow_form, %{})
    base_config = Map.get(current, "_base_config", %{})

    current
    |> deep_merge(params)
    |> Map.put("_base_config", base_config)
  end

  defp apply_project_settings(draft, nil), do: draft

  defp apply_project_settings(draft, project) do
    draft
    |> Map.put("tracker_project_slug", project_value(project, :linear_project_slug) || "")
    |> Map.put("project_repository_url", project_value(project, :repository_url) || "")
    |> Map.put("project_default_branch", project_value(project, :default_branch) || "main")
  end

  defp project_attrs(params) do
    %{
      name: Map.get(params, "name", ""),
      slug: Map.get(params, "slug", ""),
      linear_project_slug: blank_as_nil(Map.get(params, "linear_project_slug")),
      repository_url: blank_as_nil(Map.get(params, "repository_url")),
      default_branch: blank_as_nil(Map.get(params, "default_branch")) || "main",
      description: blank_as_nil(Map.get(params, "description")),
      enabled: truthy_param?(Map.get(params, "enabled"))
    }
  end

  defp project_value(project, key) do
    Map.get(project, key) || Map.get(project, to_string(key))
  end

  defp project_team_names(project) do
    project
    |> Map.get(:teams, [])
    |> Enum.map_join(", ", & &1.name)
  end

  defp changeset_or_reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end

  defp changeset_or_reason(reason), do: inspect(reason)

  defp truthy_param?(value), do: to_string(value) == "true"

  defp restore_settings_section(:agents, current, history) do
    current
    |> Map.put("prompt_body", Map.get(history, "prompt_body", ""))
    |> Map.put("profiles", Map.get(history, "profiles", %{}))
  end

  defp restore_settings_section(_workflow, current, history) do
    history
    |> Map.put("prompt_body", Map.get(current, "prompt_body", ""))
    |> Map.put("profiles", Map.get(current, "profiles", %{}))
  end

  defp append_empty_transition(draft) do
    transitions =
      draft
      |> Map.get("allowed_transitions", [])
      |> normalize_transition_entries()
      |> Kernel.++([%{"from" => "", "to" => "", "actor" => "", "profile" => ""}])

    Map.put(draft, "allowed_transitions", transitions)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value), do: deep_merge(left_value, right_value), else: right_value
    end)
  end

  defp assign_workflow_validation(socket, draft) do
    case WorkflowForm.to_raw(draft) do
      {:ok, raw} ->
        case WorkflowValidator.validate_raw(raw, runtime?: false) do
          {:ok, _validation} ->
            socket
            |> assign(:workflow_validation_error, nil)
            |> assign(:workflow_form_valid?, true)
            |> assign(:workflow_form_summary, WorkflowForm.summary(draft))

          {:error, {:workflow_validation_failed, message}} ->
            socket
            |> assign(:workflow_validation_error, message)
            |> assign(:workflow_form_valid?, false)
            |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
        end

      {:error, message} ->
        socket
        |> assign(:workflow_validation_error, message)
        |> assign(:workflow_form_valid?, false)
        |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
    end
  end

  defp persistence, do: PersistenceProvider.module()

  defp orchestrator do
    SymphonyElixirWeb.Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp safe_import_workflow(project, raw, source) do
    persistence().import_workflow(project, raw, source)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp assign_save_notice(socket, level, title, message) do
    assign(socket, :workflow_save_notice, %{
      level: level,
      title: title,
      message: message
    })
  end

  defp runtime_workflow do
    WorkflowStore.current_with_source()
  end

  defp runtime_source_summary({:ok, %{source: source}}), do: source_summary(source)

  defp source_summary(%{type: type} = source), do: %{type: to_string(type), detail: source_detail(source)}
  defp source_summary(_source), do: %{type: "unknown", detail: "n/a"}

  defp source_detail(%{type: :database, workflow_version_id: id}), do: id || "n/a"
  defp source_detail(%{type: :setup_required}), do: "setup required"
  defp source_detail(_source), do: "n/a"

  defp profile_entries(form) do
    form
    |> Map.get("profiles", %{})
    |> Enum.sort_by(fn {profile_id, _profile} -> profile_id end)
  end

  defp workflow_state_entries(form) do
    form
    |> Map.get("workflow_states", %{})
    |> Enum.sort_by(fn {state, _attrs} -> state end)
  end

  defp transition_entries(form) do
    form
    |> Map.get("allowed_transitions", [])
    |> normalize_transition_entries()
    |> Enum.with_index()
  end

  defp normalize_transition_entries(entries) when is_list(entries), do: entries

  defp normalize_transition_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} ->
      case Integer.parse(to_string(index)) do
        {integer, ""} -> integer
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, entry} -> entry end)
  end

  defp normalize_transition_entries(_entries), do: []

  defp db_runtime_mismatch?(nil, _runtime), do: false

  defp db_runtime_mismatch?(version, {:ok, %{source: %{type: :database, workflow_version_id: id}}}) do
    version.id != id
  end

  defp db_runtime_mismatch?(_version, _runtime), do: true

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_), do: "n/a"

  defp workflow_version_summary(version) do
    inspect(
      %{
        id: Map.get(version, :id),
        version: Map.get(version, :version),
        source: Map.get(version, :source),
        active: Map.get(version, :active),
        inserted_at: Map.get(version, :inserted_at)
      },
      pretty: true
    )
  end

  defp safe_event_payload(payload) do
    payload
    |> scrub_payload()
    |> inspect(pretty: true, limit: 20)
    |> truncate(2_000)
  end

  defp scrub_payload(%{} = payload) do
    Map.new(payload, fn {key, value} ->
      key_string = to_string(key)

      if String.contains?(String.downcase(key_string), ["token", "secret", "authorization", "api_key"]) do
        {key, "[REDACTED]"}
      else
        {key, scrub_payload(value)}
      end
    end)
  end

  defp scrub_payload(value) when is_list(value), do: Enum.map(value, &scrub_payload/1)
  defp scrub_payload(value), do: value

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "\n... truncated"
  end

  defp truncate(value, _limit), do: value

  defp labels_text(%{"values" => labels}) when is_list(labels), do: Enum.join(labels, ", ")
  defp labels_text(_), do: ""

  defp status_class(status) when status in ["completed", "healthy", "online"], do: "status-badge status-success"
  defp status_class(status) when status in ["queued", "pending", "waiting"], do: "status-badge status-accent"
  defp status_class(status) when status in ["running", "retrying", "leased"], do: "status-badge status-warning"
  defp status_class(status) when status in ["failed", "offline", "expired"], do: "status-badge status-danger"
  defp status_class(_), do: "status-badge"
end
