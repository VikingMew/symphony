defmodule SymphonyElixirWeb.AdminLive do
  @moduledoc """
  Operational pages for persisted Symphony projects, runs, workflows, and settings.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{
    Config,
    EventPresenter,
    PersistenceProvider,
    ProfilePromptSummary,
    RunHistory,
    WorkflowForm,
    WorkflowSettingsPackage,
    WorkflowStore,
    WorkflowValidator
  }

  alias SymphonyElixir.Linear.{Discovery, StateFixes, WorkflowStateValidator}
  alias SymphonyElixirWeb.Admin.{ObservabilityPresenter, ProjectSettings, SettingsCheck}

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
        {:runtime, "Runtime", "/settings/runtime"},
        {:import, "Import", "/settings/import"}
      ])

    ~H"""
    <nav class="settings-tabs" aria-label="Settings sections">
      <.link
        :for={{key, label, path} <- @tabs}
        class="settings-tab-link"
        patch={path}
        aria-current={if key == @active, do: "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  attr(:status, :atom, required: true)
  attr(:discovery, :any, required: true)
  attr(:message, :any, default: nil)

  @spec linear_discovery_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_discovery_panel(assigns) do
    ~H"""
    <section class="section-card settings-content-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">Linear Configuration Discovery</h2>
          <p class="workflow-help-copy">Fetch read-only Linear projects, teams, and workflow states while filling project and workflow settings.</p>
        </div>
        <button type="button" class="subtle-button" phx-click="fetch_linear_discovery" phx-disable-with="Fetching...">
          <%= if @status == :fetched, do: "Refresh Linear configuration", else: "Fetch Linear configuration" %>
        </button>
      </div>

      <p :if={@message} class="status-note"><%= @message %></p>

      <%= case @discovery do %>
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
      <% end %>
    </section>
    """
  end

  attr(:notice, :any, default: nil)

  @spec settings_import_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_import_panel(assigns) do
    ~H"""
    <section class="workflow-form-section settings-import-panel">
      <div class="workflow-form-header settings-action-row">
        <div>
          <h3>Import Settings Package</h3>
          <p class="workflow-help-copy">Import workflow.yml or profiles.yml into this structured draft. Symphony detects the file type from YAML fields. Import does not save or activate until you press Save.</p>
        </div>
        <span class="status-badge status-info">draft only</span>
      </div>

      <%= if @notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@notice.level}"]} role="status" aria-live="polite">
          <strong><%= @notice.title %></strong>
          <span><%= @notice.message %></span>
        </aside>
      <% end %>

      <form class="workflow-form settings-import-form" phx-submit="import_settings_package">
        <label>
          <span class="metric-label">YAML</span>
          <textarea class="workflow-textbox workflow-textbox-medium" name="import[yaml]" rows="7" placeholder="Paste workflow.yml or profiles.yml"></textarea>
        </label>
        <button class="subtle-button" type="submit" phx-disable-with="Importing...">Import</button>
      </form>
    </section>
    """
  end

  attr(:discovery, :any, required: true)

  @spec linear_project_discovery(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_project_discovery(assigns) do
    ~H"""
    <%= case @discovery do %>
      <% {:ok, discovery} -> %>
        <section class="workflow-form-section">
          <h3>Linear Project Candidates</h3>
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
                    <td><%= ProjectSettings.team_names(project) %></td>
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
        </section>
      <% _ -> %>
    <% end %>
    """
  end

  attr(:discovery, :any, required: true)
  attr(:draft, :map, required: true)

  @spec linear_workflow_discovery(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_workflow_discovery(assigns) do
    assigns =
      assign(assigns, :state_check, linear_workflow_state_check(assigns.draft, assigns.discovery))

    ~H"""
    <%= case @discovery do %>
      <% {:ok, discovery} -> %>
        <section class="workflow-form-section">
          <h3>Linear Workflow State Candidates</h3>
          <.linear_workflow_state_check_panel state_check={@state_check} />
          <div class="diagnostics-grid">
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
        </section>
      <% _ -> %>
    <% end %>
    """
  end

  attr(:state_check, :any, required: true)

  @spec linear_workflow_state_check_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_workflow_state_check_panel(assigns) do
    ~H"""
    <%= case @state_check do %>
      <% {:ok, %{status: :ok}} -> %>
        <aside class="setup-guidance-card" role="status" aria-live="polite">
          <h3>Linear state check</h3>
          <p>Configured workflow states match the fetched Linear states.</p>
        </aside>
      <% {:ok, %{status: :error} = check} -> %>
        <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
          <h3>Linear state check</h3>
          <p>Settings are structurally valid, but these state names do not exist in the fetched Linear project. Rename them in Settings / Workflow or create the missing Linear statuses.</p>
          <ul>
            <li :for={item <- StateFixes.items(check)}>
              <div class="setup-guidance-item-heading">
                <span class="status-badge status-danger"><%= item.state %></span>
                <strong><%= item.references %></strong>
              </div>
              <span><%= item.action %></span>
            </li>
          </ul>
        </aside>
      <% _ -> %>
    <% end %>
    """
  end

  attr(:field, :string, required: true)
  attr(:errors, :map, required: true)

  @spec workflow_field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def workflow_field_error(assigns) do
    ~H"""
    <p :if={Map.has_key?(@errors, @field)} class="field-error">
      <%= Map.fetch!(@errors, @field) %>
    </p>
    """
  end

  attr(:targets, :list, required: true)
  attr(:tab, :atom, required: true)
  attr(:field, :atom, required: true)
  attr(:scope, :any, default: nil)

  @spec settings_check_messages(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_check_messages(assigns) do
    assigns = assign(assigns, :messages, SettingsCheck.messages(assigns.targets, assigns.tab, assigns.field, assigns.scope))

    ~H"""
    <p :for={message <- @messages} class="settings-check-message"><%= message %></p>
    """
  end

  attr(:targets, :list, required: true)
  attr(:current_tab, :atom, required: true)

  @spec settings_check_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_check_summary(assigns) do
    ~H"""
    <aside :if={@targets != []} class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
      <h3>Configuration check targets</h3>
      <ul>
        <li :for={target <- @targets}>
          <div class="setup-guidance-item-heading">
            <span class="status-badge status-danger"><%= settings_tab_label(target.tab) %></span>
            <strong><%= target.title %></strong>
          </div>
          <span><%= target.message %></span>
          <a :if={target.tab != @current_tab} class="issue-link" href={settings_tab_path(target.tab)}>Open <%= settings_tab_label(target.tab) %></a>
        </li>
      </ul>
    </aside>
    """
  end

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
     |> allow_upload(:settings_package, accept: :any, max_entries: 1, max_file_size: 128_000)
     |> refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:route_params, params)
     |> refresh()}
  end

  @impl true
  def handle_event("fetch_linear_discovery", _params, socket) do
    case Discovery.fetch() do
      {:ok, discovery} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:ok, discovery})
         |> assign(:linear_discovery_status, :fetched)
         |> assign(:linear_discovery_message, "Fetched at #{fmt_dt(discovery.fetched_at)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:error, reason})
         |> assign(:linear_discovery_status, :failed)
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
     |> assign(:workflow_form_dirty?, true)
     |> assign_workflow_validation(draft)}
  end

  @impl true
  def handle_event("validate_settings_import_upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stage_settings_import", %{"import" => params}, socket) do
    pasted = Map.get(params, "yaml", "")
    yaml = import_upload_content(socket) || pasted
    source = import_source(socket, pasted)

    socket =
      with :ok <- WorkflowSettingsPackage.require_import_content(yaml),
           {:ok, stage} <- WorkflowSettingsPackage.stage_import(yaml, socket.assigns.workflow_form, source: source) do
        socket
        |> put_flash(:info, "#{stage.label} staged for review.")
        |> assign_import_notice(
          :success,
          "#{stage.label} staged",
          "Review the detected changes, then confirm to update the editable Settings draft."
        )
        |> assign(:settings_import_yaml, yaml)
        |> assign(:settings_import_stage, stage)
      else
        {:error, reason} ->
          message = WorkflowSettingsPackage.import_error_message(reason)

          socket
          |> put_flash(:error, "Settings package import failed: #{message}")
          |> assign_import_notice(:error, "Package import failed", message)
          |> assign(:settings_import_stage, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_settings_import", _params, socket) do
    case socket.assigns.settings_import_stage do
      %{draft: draft, label: label, owning_tab: owning_tab} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{label} applied to the editable draft. Save #{settings_section_label(owning_tab)} to activate it.")
         |> assign_import_notice(:success, "#{label} applied to draft", "Runtime configuration is unchanged until you save.")
         |> assign(:workflow_save_notice, nil)
         |> assign(:workflow_validation_visible?, true)
         |> assign(:workflow_form, draft)
         |> assign(:workflow_form_dirty?, true)
         |> assign(:settings_import_stage, nil)
         |> assign_workflow_validation(draft)
         |> push_patch(to: settings_tab_path(owning_tab))}

      _stage ->
        {:noreply, assign_import_notice(socket, :error, "No staged import", "Paste or upload a settings package before confirming.")}
    end
  end

  @impl true
  def handle_event("cancel_settings_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_import_stage, nil)
     |> assign(:settings_import_yaml, "")
     |> assign_import_notice(:info, "Import cancelled", "The editable Settings draft was not changed.")}
  end

  @impl true
  def handle_event("save_workflow_form", %{"workflow" => params}, socket) do
    draft = workflow_draft(socket, params) |> ProjectSettings.apply_to_workflow_draft(socket.assigns.default_project)
    section = settings_tab(socket.assigns.live_action)

    socket =
      with {:ok, raw} <- WorkflowForm.to_raw(draft),
           :changed <- workflow_change_status(raw, socket),
           {:ok, project} <- persistence().default_project(),
           {:ok, version} <- safe_import_workflow(project, raw, settings_source(section)) do
        _ = WorkflowStore.force_reload()

        socket
        |> put_flash(:info, "#{settings_section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign_save_notice(:success, "#{settings_section_label(section)} saved", "Version #{version.version} is active. Runtime workflow refreshed.")
        |> assign(:workflow_diagnostics_notice, "#{settings_section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign(:workflow_validation_visible?, true)
        |> assign(:workflow_form, draft)
        |> assign(:workflow_form_dirty?, false)
        |> assign_workflow_validation(draft)
        |> refresh()
      else
        :unchanged ->
          socket
          |> put_flash(:info, "#{settings_section_label(section)} already up to date.")
          |> assign_save_notice(:info, "#{settings_section_label(section)} already up to date", "No changes to save.")
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_dirty?, false)
          |> assign_workflow_validation(draft)

        {:error, message} when is_binary(message) ->
          socket
          |> put_flash(:error, "#{settings_section_label(section)} rejected: #{message}")
          |> assign_save_notice(:error, "#{settings_section_label(section)} save failed", "Fix highlighted fields before saving.")
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_dirty?, true)
          |> assign(:workflow_field_errors, WorkflowForm.field_errors(draft))
          |> assign(:workflow_validation_error, nil)
          |> assign(:workflow_form_valid?, false)

        {:error, reason} ->
          message = inspect(reason)

          socket
          |> put_flash(:error, "#{settings_section_label(section)} rejected: #{message}")
          |> assign_save_notice(:error, "#{settings_section_label(section)} save failed", message)
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_field_errors, %{})
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_dirty?, true)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_project_settings", %{"project" => params}, socket) do
    id = blank_as_nil(Map.get(params, "id"))
    attrs = ProjectSettings.attrs(params)

    result =
      case id do
        nil -> persistence().create_project(attrs)
        id -> maybe_update_project(id, attrs, socket)
      end

    socket =
      case result do
        :unchanged ->
          _ = WorkflowStore.force_reload()

          socket
          |> put_flash(:info, "Project settings already up to date.")
          |> assign_save_notice(:info, "Project settings already up to date", "No changes to save.")

        {:ok, project} ->
          _ = WorkflowStore.force_reload()

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
           draft <- WorkflowSettingsPackage.restore_section(section, socket.assigns.workflow_form, history_draft),
           draft <- ProjectSettings.apply_to_workflow_draft(draft, socket.assigns.default_project),
           {:ok, restored_raw} <- WorkflowForm.to_raw(draft),
           {:ok, project} <- persistence().default_project(),
           {:ok, restored_version} <- safe_import_workflow(project, restored_raw, settings_source(section)) do
        _ = WorkflowStore.force_reload()

        socket
        |> put_flash(:info, "#{settings_section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign_save_notice(:success, "#{settings_section_label(section)} restored", "Version #{restored_version.version} is active. Runtime workflow refreshed.")
        |> assign(:workflow_diagnostics_notice, "#{settings_section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
        |> assign(:workflow_validation_visible?, true)
        |> assign(:workflow_form, draft)
        |> assign(:workflow_form_dirty?, false)
        |> assign_workflow_validation(draft)
        |> refresh()
      else
        nil ->
          put_flash(socket, :error, "Settings version not found")

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
     |> assign(:workflow_form_dirty?, true)
     |> assign_workflow_validation(draft)}
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
                  <tr><th>Run ID</th><td class="mono"><%= @run_detail.run.id %></td></tr>
                  <tr><th>Issue</th><td><a class="issue-link" href={"/issues/#{@run_detail.run.issue_identifier}"}><%= @run_detail.run.issue_identifier %></a></td></tr>
                  <tr><th>Status</th><td><span class={status_class(@run_detail.run.status)}><%= @run_detail.run.status %></span></td></tr>
                  <tr><th>Attempt</th><td><%= @run_detail.run.attempt %></td></tr>
                  <tr><th>Worker</th><td><%= Map.get(@run_detail.run, :worker_host) || "local" %></td></tr>
                  <tr><th>Workspace</th><td class="mono"><%= Map.get(@run_detail.run, :workspace_path) || "n/a" %></td></tr>
                  <tr><th>Started</th><td class="mono"><%= fmt_dt(@run_detail.run.started_at) %></td></tr>
                  <tr><th>Finished</th><td class="mono"><%= fmt_dt(@run_detail.run.finished_at) %></td></tr>
                  <tr><th>Duration</th><td><%= fmt_duration(@run_detail.run.started_at, @run_detail.run.finished_at) %></td></tr>
                  <tr><th>Failure</th><td><%= Map.get(@run_detail.run, :failure_reason) || "n/a" %></td></tr>
                </tbody>
              </table>

              <h2 class="section-title">Agent Summary</h2>
              <table class="data-table">
                <tbody>
                  <tr><th>Outcome</th><td><%= @run_detail.summary.outcome %></td></tr>
                  <tr><th>Final message</th><td><%= @run_detail.summary.final_message || "No final agent message was persisted." %></td></tr>
                  <tr><th>Last Codex signal</th><td><%= @run_detail.summary.last_codex_detail || "No useful Codex signal recorded." %></td></tr>
                  <tr><th>Work performed</th><td><%= list_summary(@run_detail.summary.actions) %></td></tr>
                  <tr><th>Tools</th><td><%= list_summary(@run_detail.summary.tools) %></td></tr>
                  <tr><th>Commands</th><td><%= list_summary(@run_detail.summary.commands) %></td></tr>
                  <tr><th>Linear updates</th><td><%= list_summary(@run_detail.summary.linear_updates) %></td></tr>
                  <tr><th>Highlights</th><td><%= list_summary(@run_detail.summary.highlights) %></td></tr>
                  <tr><th>Blockers</th><td><%= list_summary(@run_detail.summary.blockers) %></td></tr>
                  <tr><th>Sessions</th><td><%= list_summary(@run_detail.summary.sessions) %></td></tr>
                  <tr><th>Evidence</th><td><%= @run_detail.summary.evidence_quality %></td></tr>
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
                <p class="empty-state">No structured agent turns recorded. Session history below is the source of truth for this run.</p>
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

              <h2 class="section-title">Session History</h2>
              <%= if @run_detail.session_history == [] do %>
                <p class="empty-state">No session history recorded for this run.</p>
              <% else %>
                <table class="data-table">
                  <thead><tr><th>Time</th><th>Source</th><th>Event</th><th>Detail</th></tr></thead>
                  <tbody>
                    <tr :for={event <- @run_detail.session_history}>
                      <td class="mono"><%= fmt_dt(event.at) %></td>
                      <td><span class={status_class(to_string(event.severity || :info))}><%= event.source || "n/a" %></span></td>
                      <td><%= event.label %></td>
                      <td>
                        <div><%= event.detail || "n/a" %></div>
                        <details :if={event.metadata != %{}} class="event-metadata">
                          <summary>Payload</summary>
                          <pre class="inline-code-panel"><%= safe_event_payload(event.metadata) %></pre>
                        </details>
                      </td>
                    </tr>
                  </tbody>
                </table>
              <% end %>

              <h2 class="section-title">Raw Events</h2>
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
            <p class="section-copy">Persisted Symphony events. Summaries are normalized for troubleshooting; raw payloads remain bounded and scrubbed.</p>
            <%= if @hidden_low_signal_event_count > 0 do %>
              <aside class="setup-guidance-card" role="status" aria-live="polite">
                <h3>Low-signal rows hidden</h3>
                <p><%= @hidden_low_signal_event_count %> empty Codex notification rows are hidden in this view. Set Hide low signal to false to reveal them.</p>
              </aside>
            <% end %>
            <form class="workflow-import-form" method="get" action="/events">
              <label><span class="metric-label">Issue</span><input name="issue_identifier" value={@event_filters.issue_identifier} /></label>
              <label><span class="metric-label">Run ID</span><input name="run_id" value={@event_filters.run_id} /></label>
              <label><span class="metric-label">Event type</span><input name="event_type" value={@event_filters.event_type} /></label>
              <label>
                <span class="metric-label">Severity</span>
                <select name="severity">
                  <option value="" selected={@event_filters.severity == ""}>all</option>
                  <option value="error" selected={@event_filters.severity == "error"}>error</option>
                  <option value="warning" selected={@event_filters.severity == "warning"}>warning</option>
                  <option value="info" selected={@event_filters.severity == "info"}>info</option>
                </select>
              </label>
              <label>
                <span class="metric-label">Source</span>
                <select name="source">
                  <option value="" selected={@event_filters.source == ""}>all</option>
                  <option value="system" selected={@event_filters.source == "system"}>system</option>
                  <option value="agent" selected={@event_filters.source == "agent"}>agent</option>
                  <option value="linear" selected={@event_filters.source == "linear"}>linear</option>
                  <option value="workspace" selected={@event_filters.source == "workspace"}>workspace</option>
                  <option value="worker" selected={@event_filters.source == "worker"}>worker</option>
                </select>
              </label>
              <label>
                <span class="metric-label">Hide low signal</span>
                <select name="hide_low_signal">
                  <option value="true" selected={@event_filters.hide_low_signal != "false"}>true</option>
                  <option value="false" selected={@event_filters.hide_low_signal == "false"}>false</option>
                </select>
              </label>
              <label><span class="metric-label">Limit</span><input type="number" min="1" max="500" name="limit" value={@event_filters.limit} /></label>
              <button class="subtle-button" type="submit">Apply filters</button>
            </form>
            <div class="button-row">
              <a class="subtle-button" href="/events?severity=error">Errors only</a>
              <a class="subtle-button" href="/events?source=workspace">Workspace</a>
              <a class="subtle-button" href="/events?source=linear">Linear</a>
              <a class="subtle-button" href="/events?source=agent&hide_low_signal=false">Codex raw</a>
            </div>

            <%= if @event_rows == [] do %>
              <p class="empty-state">No events recorded.</p>
            <% else %>
              <table class="data-table events-table">
                <thead><tr><th>Time</th><th>Issue</th><th>Run</th><th>Source</th><th>Severity</th><th>Type</th><th>Summary</th><th>Raw</th></tr></thead>
                <tbody>
                  <tr :for={event <- @event_rows}>
                    <td class="mono"><%= fmt_dt(event.occurred_at) %></td>
                    <td>
                      <a :if={event.issue_identifier} class="issue-link" href={"/issues/#{event.issue_identifier}"}><%= event.issue_identifier %></a>
                      <span :if={is_nil(event.issue_identifier)} class="muted">n/a</span>
                    </td>
                    <td>
                      <a :if={event.run_id} class="issue-link mono" href={"/runs/#{event.run_id}"}><%= event.run_id %></a>
                      <span :if={is_nil(event.run_id)} class="muted">n/a</span>
                    </td>
                    <td><span class="status-badge status-info"><%= event.source %></span></td>
                    <td><span class={status_class(to_string(event.severity))}><%= event.severity %></span></td>
                    <td><a class="issue-link" href={"/events?event_type=#{event.event_type}"}><%= event.event_type %></a></td>
                    <td>
                      <div class="detail-stack">
                        <strong><%= event.summary %></strong>
                        <span class="muted"><%= event.detail %></span>
                        <span :if={event.low_signal?} class="status-badge">low signal</span>
                      </div>
                    </td>
                    <td>
                      <details>
                        <summary>Raw payload</summary>
                        <pre class="inline-code-panel"><%= safe_event_payload(event.raw_payload) %></pre>
                      </details>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </section>

        <% action when action in [:settings, :settings_projects, :settings_workflow, :settings_agents, :settings_runtime, :settings_import] -> %>
          <section class="section-card settings-header-card">
            <h1 class="section-title">Settings</h1>
            <p class="metric-label">Configure projects, workflow routing, agent profiles, and runtime settings.</p>
            <.settings_tabs active={settings_tab(action)} />
          </section>

          <%= if settings_tab(action) in [:projects, :workflow] do %>
            <.linear_discovery_panel status={@linear_discovery_status} discovery={@linear_discovery} message={@linear_discovery_message} />
          <% end %>

          <%= case settings_tab(action) do %>
            <% :projects -> %>
          <section class="section-card settings-content-card">
            <h2 class="section-title">Projects</h2>
            <p class="metric-label">Each project owns its Linear project slug, repository URL, and default branch. Workflow and agent policy remain shared.</p>
            <%= if @project_configuration_items != [] do %>
              <aside class="setup-guidance-card" role="status" aria-live="polite">
                <h3>Project configuration checklist</h3>
                <ul>
                  <li :for={item <- @project_configuration_items}>
                    <div class="setup-guidance-item-heading">
                      <span class="status-badge status-info"><%= item.scope %></span>
                      <strong><%= item.title %></strong>
                    </div>
                    <span><%= item.detail %></span>
                  </li>
                </ul>
              </aside>
            <% end %>

            <.linear_project_discovery discovery={@linear_discovery} />

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
                    <label class={project_field_class(@project_configuration_items, "Linear project slug")}><span class={project_field_title_class(@project_configuration_items, "Linear project slug")}>Linear project slug</span><input name="project[linear_project_slug]" value={ProjectSettings.value(project, :linear_project_slug)} /></label>
                    <label class={project_field_class(@project_configuration_items, "Repository URL")}><span class={project_field_title_class(@project_configuration_items, "Repository URL")}>Repository URL</span><input name="project[repository_url]" value={ProjectSettings.value(project, :repository_url)} /></label>
                    <label class="settings-field"><span class="metric-label">Default branch</span><input name="project[default_branch]" value={ProjectSettings.value(project, :default_branch) || "main"} /></label>
                    <label class="settings-field"><span class="metric-label">Checkout depth</span><input type="number" min="1" name="project[checkout_depth]" value={ProjectSettings.value(project, :checkout_depth) || 1} /></label>
                    <label class="settings-field">
                      <span class="metric-label">Source strategy</span>
                      <select name="project[source_strategy]">
                        <option value="clone" selected={ProjectSettings.value(project, :source_strategy) in [nil, "clone"]}>clone</option>
                        <option value="worktree" selected={ProjectSettings.value(project, :source_strategy) == "worktree"}>worktree</option>
                      </select>
                    </label>
                    <div class="workflow-checkbox-row">
                      <input type="hidden" name="project[worktree_fetch]" value="false" />
                      <label><input type="checkbox" name="project[worktree_fetch]" value="true" checked={ProjectSettings.value(project, :worktree_fetch) != false} /> Fetch before worktree</label>
                      <input type="hidden" name="project[worktree_cleanup]" value="false" />
                      <label><input type="checkbox" name="project[worktree_cleanup]" value="true" checked={ProjectSettings.value(project, :worktree_cleanup) != false} /> Clean stale worktree</label>
                    </div>
                    <label class="settings-field"><span class="metric-label">Description</span><input name="project[description]" value={ProjectSettings.value(project, :description)} /></label>
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
                  <label class="settings-field"><span class="metric-label">Checkout depth</span><input type="number" min="1" name="project[checkout_depth]" value="1" /></label>
                  <label class="settings-field">
                    <span class="metric-label">Source strategy</span>
                    <select name="project[source_strategy]">
                      <option value="clone" selected>clone</option>
                      <option value="worktree">worktree</option>
                    </select>
                  </label>
                  <div class="workflow-checkbox-row">
                    <input type="hidden" name="project[worktree_fetch]" value="false" />
                    <label><input type="checkbox" name="project[worktree_fetch]" value="true" checked /> Fetch before worktree</label>
                    <input type="hidden" name="project[worktree_cleanup]" value="false" />
                    <label><input type="checkbox" name="project[worktree_cleanup]" value="true" checked /> Clean stale worktree</label>
                  </div>
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

            <% :import -> %>
          <section class="section-card settings-content-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Import Settings Package</h2>
                <p class="section-copy">Paste or upload workflow.yml or profiles.yml. Import is staged for review before it changes the editable draft, and runtime configuration is unchanged until the normal Save flow.</p>
              </div>
              <span class="status-badge status-info">staged review</span>
            </div>

            <%= if @workflow_import_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_import_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_import_notice.title %></strong>
                <span><%= @workflow_import_notice.message %></span>
              </aside>
            <% end %>

            <form class="workflow-form settings-editor-form" phx-submit="stage_settings_import" phx-change="validate_settings_import_upload">
              <section class="workflow-form-section">
                <h3>Source</h3>
                <label>
                  <span class="metric-label">Paste YAML</span>
                  <textarea class="workflow-textbox workflow-textbox-medium" name="import[yaml]" rows="8" placeholder="Paste workflow.yml or profiles.yml"><%= @settings_import_yaml %></textarea>
                </label>
                <label>
                  <span class="metric-label">Upload file</span>
                  <.live_file_input upload={@uploads.settings_package} />
                </label>
                <button class="subtle-button" type="submit" phx-disable-with="Reviewing...">Review import</button>
              </section>
            </form>

            <%= if @settings_import_stage do %>
              <section class="workflow-form-section settings-import-review">
                <div class="workflow-form-header settings-action-row">
                  <div>
                    <h3>Review staged import</h3>
                    <p class="workflow-help-copy">
                      Detected <span class="mono"><%= @settings_import_stage.label %></span>.
                      Affects <%= Enum.join(@settings_import_stage.affected_areas, ", ") %>.
                    </p>
                  </div>
                  <span class="status-badge status-info"><%= @settings_import_stage.source %></span>
                </div>
                <div class="workflow-summary-grid">
                  <p><span class="metric-label">Package type</span><strong><%= @settings_import_stage.detected_type %></strong></p>
                  <p><span class="metric-label">Changes</span><strong><%= length(@settings_import_stage.diff) %></strong></p>
                  <p><span class="metric-label">Next page</span><strong><%= settings_tab_label(@settings_import_stage.owning_tab) %></strong></p>
                </div>
                <%= if @settings_import_stage.diff == [] do %>
                  <p class="empty-state">No draft changes detected.</p>
                <% else %>
                  <div class="table-wrap">
                    <table class="data-table settings-import-diff-table">
                      <thead><tr><th>Area</th><th>Field</th><th>Before</th><th>After</th></tr></thead>
                      <tbody>
                        <tr :for={change <- @settings_import_stage.diff}>
                          <td><span class="status-badge status-info"><%= change.area %></span></td>
                          <td class="mono"><%= change.path %></td>
                          <td><pre class="inline-code-panel"><%= change.before %></pre></td>
                          <td><pre class="inline-code-panel"><%= change.after %></pre></td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
                <details>
                  <summary>Raw source preview</summary>
                  <pre class="code-panel"><%= @settings_import_stage.preview %></pre>
                </details>
                <div class="button-row">
                  <button type="button" class="subtle-button" phx-click="confirm_settings_import" phx-disable-with="Applying...">Confirm import to draft</button>
                  <button type="button" class="subtle-button" phx-click="cancel_settings_import">Cancel</button>
                </div>
              </section>
            <% end %>
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
            <%= if @workflow_configuration_items != [] do %>
              <aside class="setup-guidance-card" role="status" aria-live="polite">
                <h3>Workflow configuration checklist</h3>
                <ul>
                  <li :for={item <- @workflow_configuration_items}>
                    <div class="setup-guidance-item-heading">
                      <span class="status-badge status-info"><%= item.scope %></span>
                      <strong><%= item.title %></strong>
                    </div>
                    <span><%= item.detail %></span>
                    <a :if={item.href} class="issue-link" href={item.href}><%= item.action %></a>
                  </li>
                </ul>
              </aside>
            <% end %>
            <.linear_workflow_discovery discovery={@linear_discovery} draft={@workflow_form} />
            <%= if @workflow_diagnostics_notice do %>
              <p class="empty-state">
                <%= @workflow_diagnostics_notice %>
                <a class="issue-link" href="/diagnostics/linear">Open Linear diagnostics</a>
              </p>
            <% end %>
            <%= if @workflow_validation_visible? && map_size(@workflow_field_errors) > 0 do %>
              <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
                <h3>Field errors</h3>
                <p>Fix the highlighted field values, then save again. These are local field format issues, not workflow semantics.</p>
                <ul>
                  <li :for={{field, message} <- @workflow_field_errors}>
                    <a class="issue-link" href={"##{workflow_field_id(field)}"}><%= workflow_field_label(field) %></a>
                    <span><%= message %></span>
                  </li>
                </ul>
              </aside>
            <% end %>
            <%= if @workflow_validation_visible? && @workflow_validation_error do %>
              <p class="error-copy"><strong>Configuration check failed:</strong> <%= @workflow_validation_error %></p>
              <.settings_check_summary targets={@workflow_check_targets} current_tab={:workflow} />
            <% end %>
            <%= if @workflow_save_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_save_notice.title %></strong>
                <span><%= @workflow_save_notice.message %></span>
              </aside>
            <% end %>
            <form class="workflow-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
              <div class="workflow-form-header">
                <div>
                  <h2 class="section-title">Draft Configuration</h2>
                  <p class="metric-label">Edit fields, review validation, then save a database workflow version.</p>
                </div>
                <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save workflow version</button>
              </div>

              <div class="workflow-summary-grid">
                <p><span class="metric-label">Tracker</span><strong><%= @workflow_form_summary.tracker %></strong></p>
                <p><span class="metric-label">Active states</span><strong><%= @workflow_form_summary.active_states %></strong></p>
                <p><span class="metric-label">Terminal states</span><strong><%= @workflow_form_summary.terminal_states %></strong></p>
                <p><span class="metric-label">Hooks</span><strong><%= @workflow_form_summary.hooks %></strong></p>
                <p><span class="metric-label">Setup commands</span><strong><%= @workflow_form_summary.setup_commands %></strong></p>
                <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
              </div>

              <div class="workflow-form-grid">
                <section class={settings_check_class(@workflow_check_targets, :workflow, :tracker_section, nil, "workflow-form-section")}>
                  <h3 class={settings_check_title_class(@workflow_check_targets, :workflow, :tracker_section)}>Tracker</h3>
                  <p class="metric-label">Linear tracker is managed by shared runtime configuration. Project-specific Linear slugs are configured in Settings / Projects.</p>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :tracker_assignee)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :tracker_assignee)}>Assignee</span><input name="workflow[tracker_assignee]" value={@workflow_form["tracker_assignee"]} /></label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :active_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :active_states)}>Active states</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[active_states]" rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :active_states)}><%= @workflow_form["active_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:active_states} /></label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :terminal_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :terminal_states)}>Terminal states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[terminal_states]" rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :terminal_states)}><%= @workflow_form["terminal_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:terminal_states} /></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Bootstrap</h3>
                  <p class="metric-label">Project checkout source is configured per project in Settings / Projects.</p>
                  <label>
                    <span class="metric-label">Initialize timeout ms</span>
                    <input id={workflow_field_id("initialize_timeout_ms")} class={workflow_field_class(@workflow_field_errors, "initialize_timeout_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "initialize_timeout_ms")} type="number" min="1" name="workflow[initialize_timeout_ms]" value={@workflow_form["initialize_timeout_ms"]} />
                    <.workflow_field_error field="initialize_timeout_ms" errors={@workflow_field_errors} />
                  </label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :setup_commands)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :setup_commands)}>Setup commands</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[project_setup_commands]" rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :setup_commands)}><%= @workflow_form["project_setup_commands"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:setup_commands} /></label>
                  <label><span class="metric-label">Cleanup commands</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[project_cleanup_commands]" rows="4"><%= @workflow_form["project_cleanup_commands"] %></textarea></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Lifecycle Hooks</h3>
                  <p class="workflow-help-copy">
                    Hooks execute shell commands in the issue workspace after initialization. Project checkout and setup use Initialize timeout ms, then after_create runs with the hook timeout below.
                  </p>
                  <label>
                    <span class="metric-label">Hook timeout ms</span>
                    <input id={workflow_field_id("hook_timeout_ms")} class={workflow_field_class(@workflow_field_errors, "hook_timeout_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "hook_timeout_ms")} type="number" min="1" name="workflow[hook_timeout_ms]" value={@workflow_form["hook_timeout_ms"]} />
                    <.workflow_field_error field="hook_timeout_ms" errors={@workflow_field_errors} />
                  </label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_after_create)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_after_create)}>after_create</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_create]" rows="4"><%= @workflow_form["hook_after_create"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_after_create} /></label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_before_run)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_before_run)}>before_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_run]" rows="3"><%= @workflow_form["hook_before_run"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_before_run} /></label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_after_run)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_after_run)}>after_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_run]" rows="3"><%= @workflow_form["hook_after_run"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_after_run} /></label>
                  <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_before_remove)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_before_remove)}>before_remove</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_remove]" rows="3"><%= @workflow_form["hook_before_remove"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_before_remove} /></label>
                </section>

                <section class="workflow-form-section">
                  <h3>Runtime</h3>
                  <label><span class="metric-label">Clone workspace root</span><input name="workflow[workspace_root]" value={@workflow_form["workspace_root"]} /></label>
                  <label><span class="metric-label">Repository base root</span><input name="workflow[workspace_repository_base_root]" value={@workflow_form["workspace_repository_base_root"]} placeholder="Defaults to clone workspace root/repositories" /></label>
                  <label><span class="metric-label">Worktree base root</span><input name="workflow[workspace_worktree_base_root]" value={@workflow_form["workspace_worktree_base_root"]} placeholder="Defaults to clone workspace root/worktrees" /></label>
                  <div class="settings-derived-preview">
                    <span class="metric-label">Derived paths</span>
                    <code><%= ProjectSettings.repository_preview(@workflow_form, @projects) %></code>
                    <code><%= ProjectSettings.worktree_preview(@workflow_form) %></code>
                  </div>
                  <label>
                    <span class="metric-label">Polling interval ms</span>
                    <input id={workflow_field_id("polling_interval_ms")} class={workflow_field_class(@workflow_field_errors, "polling_interval_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "polling_interval_ms")} type="number" min="1" name="workflow[polling_interval_ms]" value={@workflow_form["polling_interval_ms"]} />
                    <.workflow_field_error field="polling_interval_ms" errors={@workflow_field_errors} />
                  </label>
                  <label>
                    <span class="metric-label">Max agents</span>
                    <input id={workflow_field_id("agent_max_concurrent_agents")} class={workflow_field_class(@workflow_field_errors, "agent_max_concurrent_agents")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "agent_max_concurrent_agents")} type="number" min="1" name="workflow[agent_max_concurrent_agents]" value={@workflow_form["agent_max_concurrent_agents"]} />
                    <.workflow_field_error field="agent_max_concurrent_agents" errors={@workflow_field_errors} />
                  </label>
                  <label>
                    <span class="metric-label">Max turns</span>
                    <input id={workflow_field_id("agent_max_turns")} class={workflow_field_class(@workflow_field_errors, "agent_max_turns")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "agent_max_turns")} type="number" min="1" name="workflow[agent_max_turns]" value={@workflow_form["agent_max_turns"]} />
                    <.workflow_field_error field="agent_max_turns" errors={@workflow_field_errors} />
                  </label>
                </section>

                <section class="workflow-form-section">
                  <h3>Codex</h3>
                  <label><span class="metric-label">Command</span><input name="workflow[codex_command]" value={@workflow_form["codex_command"]} /></label>
                  <label>
                    <span class="metric-label">Pre-start commands</span>
                    <textarea class="workflow-textbox workflow-textbox-compact" name="workflow[codex_pre_start_commands]" rows="4" placeholder="source ~/.nvs/nvs.sh&#10;nvs use 22 &gt;/dev/null"><%= @workflow_form["codex_pre_start_commands"] %></textarea>
                  </label>
                  <label>
                    <span class="metric-label">Approval policy</span>
                    <select name="workflow[codex_approval_policy]">
                      <option :for={policy <- codex_approval_policy_options()} value={policy} selected={@workflow_form["codex_approval_policy"] == policy}><%= policy %></option>
                    </select>
                  </label>
                  <label>
                    <span class="metric-label">Thread sandbox</span>
                    <input name="workflow[codex_thread_sandbox]" value={@workflow_form["codex_thread_sandbox"]} />
                    <span class="settings-help">Thread startup policy. Turn sandbox below controls per-turn file and network access.</span>
                  </label>
                  <label>
                    <span class="metric-label">Turn sandbox</span>
                    <select name="workflow[codex_turn_sandbox_preset]">
                      <option value="workspace_write_no_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_no_network"}>Workspace write, no network</option>
                      <option value="workspace_write_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_network"}>Workspace write, network enabled</option>
                      <option value="danger_full_access" selected={@workflow_form["codex_turn_sandbox_preset"] == "danger_full_access"}>Danger full access</option>
                      <option value="custom" selected={@workflow_form["codex_turn_sandbox_preset"] == "custom"}>Custom JSON</option>
                    </select>
                    <span class="settings-help">This is sent as Codex turn/start sandboxPolicy. Use network enabled or danger full access when agent turns must push or fetch.</span>
                  </label>
                  <label>
                    <span class="metric-label">Custom turn sandbox JSON</span>
                    <textarea id={workflow_field_id("codex_turn_sandbox_json")} class={["workflow-textbox workflow-textbox-compact", workflow_field_class(@workflow_field_errors, "codex_turn_sandbox_json")]} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "codex_turn_sandbox_json")} name="workflow[codex_turn_sandbox_json]" rows="6" placeholder={~s({"type":"workspaceWrite","networkAccess":true})}><%= @workflow_form["codex_turn_sandbox_json"] %></textarea>
                    <.workflow_field_error field="codex_turn_sandbox_json" errors={@workflow_field_errors} />
                  </label>
                </section>
              </div>

              <section class="workflow-form-section">
                <h3>Workflow Phases / State Routing</h3>
                <div class="workflow-routing-grid">
                  <label :for={{state, attrs} <- workflow_state_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :workflow, :workflow_state, state)}>
                    <span class={settings_check_title_class(@workflow_check_targets, :workflow, :workflow_state, state)}><%= state %></span>
                    <select name={"workflow[workflow_states][#{state}][profile]"}>
                      <option value="">No profile</option>
                      <option :for={profile <- WorkflowForm.profile_options(@workflow_form)} value={profile} selected={attrs["profile"] == profile}><%= profile %></option>
                    </select>
                    <.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:workflow_state} scope={state} />
                  </label>
                </div>
                <label class={settings_check_class(@workflow_check_targets, :workflow, :human_review_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :human_review_states)}>Human review states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[human_review_states]" rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :human_review_states)}><%= @workflow_form["human_review_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:human_review_states} /></label>
                <div>
                  <div class="workflow-subsection-heading">
                    <span class={settings_check_title_class(@workflow_check_targets, :workflow, :allowed_transitions)}>Allowed transitions</span>
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
                    <div :for={{transition, index} <- transition_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :workflow, :allowed_transition, index, "workflow-transition-row")}>
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
                      <.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:allowed_transition} scope={index} />
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
                      <button class="subtle-button" phx-click="restore_settings_version" phx-value-id={version.id} phx-disable-with="Restoring...">Restore workflow settings</button>
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
            <%= if @workflow_validation_visible? && map_size(@workflow_field_errors) > 0 do %>
              <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
                <h3>Field errors</h3>
                <p>Fix the highlighted field values, then save again. These are local field format issues, not workflow semantics.</p>
              </aside>
            <% end %>
            <%= if @workflow_validation_visible? && @workflow_validation_error do %>
              <p class="error-copy"><strong>Configuration check failed:</strong> <%= @workflow_validation_error %></p>
              <.settings_check_summary targets={@workflow_check_targets} current_tab={:agents} />
            <% end %>
            <%= if @workflow_save_notice do %>
              <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
                <strong><%= @workflow_save_notice.title %></strong>
                <span><%= @workflow_save_notice.message %></span>
              </aside>
            <% end %>

            <form class="workflow-form settings-editor-form agent-settings-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
              <div class="workflow-form-header settings-action-row">
                <div>
                  <h2 class="section-title">Profile Configuration</h2>
                  <p class="metric-label">Edit agent execution profiles, prompt composition, update permissions, and target states.</p>
                </div>
                <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save agent settings</button>
              </div>

              <div class="workflow-summary-grid">
                <p><span class="metric-label">Profiles</span><strong><%= @workflow_form_summary.profiles %></strong></p>
                <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
                <% prompt_page_summary = profile_prompt_page_summary(@workflow_form) %>
                <p><span class="metric-label">Base prompt</span><strong><%= prompt_page_summary.base_chars %> chars</strong></p>
                <p><span class="metric-label">Profile templates</span><strong><%= prompt_page_summary.profiles_with_templates %></strong></p>
                <p><span class="metric-label">Prompt warnings</span><strong><%= prompt_page_summary.profiles_with_warnings %></strong></p>
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
                  <article :for={{profile_id, profile} <- profile_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :agents, :profile_panel, profile_id, "workflow-profile-panel")}>
                    <% prompt_summary = profile_prompt_summary(@workflow_form, profile_id, profile) %>
                    <header class="workflow-profile-header">
                      <div>
                        <h4 class={settings_check_title_class(@workflow_check_targets, :agents, :profile_panel, profile_id)}><%= profile["name"] || profile_id %></h4>
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
                        <div class={settings_check_class(@workflow_check_targets, :agents, :profile_name, profile_id, "agent-field")}>
                          <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_name, profile_id, "agent-field-label")} for={"profile-#{profile_id}-name"}>Name</label>
                          <input id={"profile-#{profile_id}-name"} name={"workflow[profiles][#{profile_id}][name]"} value={profile["name"]} aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_name, profile_id)} />
                          <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_name} scope={profile_id} />
                        </div>
                      </section>

                      <section class="profile-field-group">
                        <h5>Execution</h5>
                        <div class={settings_check_class(@workflow_check_targets, :agents, :profile_executor, profile_id, "agent-field")}>
                          <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_executor, profile_id, "agent-field-label")} for={"profile-#{profile_id}-executor"}>Executor</label>
                          <select id={"profile-#{profile_id}-executor"} name={"workflow[profiles][#{profile_id}][executor_type]"}>
                            <option value="codex_agent" selected={profile["executor_type"] == "codex_agent"}>codex_agent</option>
                            <option value="backend_action" selected={profile["executor_type"] == "backend_action"}>backend_action</option>
                            <option value="manual" selected={profile["executor_type"] == "manual"}>manual</option>
                            <option value="external_worker" selected={profile["executor_type"] == "external_worker"}>external_worker</option>
                          </select>
                          <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_executor} scope={profile_id} />
                        </div>
                      </section>

                      <section class="profile-field-group profile-field-group-prompt">
                        <h5>Prompt</h5>
                        <div class="profile-prompt-guidance">
                          <div class="profile-prompt-metrics">
                            <span><strong><%= prompt_summary.template_chars %></strong> template chars</span>
                            <span><strong><%= format_prompt_chars(prompt_summary.effective_chars) %></strong> effective chars</span>
                            <span><%= if prompt_summary.uses_base_prompt?, do: "Base Prompt used", else: "Base Prompt not used" %></span>
                          </div>
                          <p class="metric-detail"><%= prompt_summary.composition %></p>
                          <p :if={prompt_summary.warning} class="error-copy"><%= prompt_summary.warning %></p>
                          <details class="profile-prompt-preview">
                            <summary>Preview effective prompt</summary>
                            <pre class="inline-code-panel"><%= truncate(prompt_summary.preview, 1_200) %></pre>
                          </details>
                        </div>
                        <div class="profile-prompt-layout">
                          <div class={settings_check_class(@workflow_check_targets, :agents, :profile_prompt_mode, profile_id, "agent-field profile-prompt-mode-field")}>
                            <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_prompt_mode, profile_id, "agent-field-label")} for={"profile-#{profile_id}-prompt-mode"}>Prompt mode</label>
                            <select id={"profile-#{profile_id}-prompt-mode"} name={"workflow[profiles][#{profile_id}][prompt_mode]"}>
                              <option value="extend" selected={profile["prompt_mode"] == "extend"}>extend</option>
                              <option value="replace" selected={profile["prompt_mode"] == "replace"}>replace</option>
                              <option value="disabled" selected={profile["prompt_mode"] == "disabled"}>disabled</option>
                            </select>
                            <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_prompt_mode} scope={profile_id} />
                          </div>
                          <div class={settings_check_class(@workflow_check_targets, :agents, :profile_prompt_template, profile_id, "agent-field agent-field-full")}>
                            <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_prompt_template, profile_id, "agent-field-label")} for={"profile-#{profile_id}-prompt-template"}>Profile prompt template</label>
                            <textarea id={"profile-#{profile_id}-prompt-template"} class="workflow-textbox workflow-textbox-profile" name={"workflow[profiles][#{profile_id}][prompt_template]"} rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_prompt_template, profile_id)}><%= profile["prompt_template"] %></textarea>
                            <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_prompt_template} scope={profile_id} />
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
                        <div class={settings_check_class(@workflow_check_targets, :agents, :profile_target_states, profile_id, "agent-field")}>
                          <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_target_states, profile_id, "agent-field-label")} for={"profile-#{profile_id}-target-states"}>Allowed target states</label>
                          <textarea id={"profile-#{profile_id}-target-states"} class="workflow-textbox workflow-textbox-compact" name={"workflow[profiles][#{profile_id}][target_states]"} rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_target_states, profile_id)}><%= profile["target_states"] %></textarea>
                          <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_target_states} scope={profile_id} />
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
                      <button class="subtle-button" phx-click="restore_settings_version" phx-value-id={version.id} phx-disable-with="Restoring...">Restore agent settings</button>
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
            <%= if @runtime_configuration_items != [] do %>
              <aside class="setup-guidance-card" role="status" aria-live="polite">
                <h3>Runtime configuration checklist</h3>
                <ul>
                  <li :for={item <- @runtime_configuration_items}>
                    <div class="setup-guidance-item-heading">
                      <span class="status-badge status-info"><%= item.scope %></span>
                      <strong><%= item.title %></strong>
                    </div>
                    <span><%= item.detail %></span>
                  </li>
                </ul>
              </aside>
            <% end %>
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
    {loaded_workflow_form, workflow_setup_required} = workflow_form(active, runtime)
    workflow_form = refreshed_workflow_form(socket, loaded_workflow_form)
    default_project = default_project()

    configuration_items = ProjectSettings.configuration_missing_items(workflow_setup_required, default_project)

    socket
    |> assign(:projects, persistence().list_projects())
    |> assign(:default_project, default_project)
    |> assign(:active_workflow_version, active)
    |> assign(:runs, persistence().list_runs(limit: 100))
    |> assign(:events, event_list(socket))
    |> assign(:event_filters, event_filters(socket))
    |> assign_event_rows()
    |> assign(:tasks, persistence().list_tasks(limit: 100))
    |> assign(:task_leases, persistence().list_task_leases(limit: 100))
    |> assign(:execution_mode, Config.execution_mode())
    |> assign(:workflow_versions, persistence().list_workflow_versions())
    |> assign(:tracker_configs, persistence().list_tracker_configs())
    |> assign(:workflow_form, workflow_form)
    |> assign_workflow_validation(workflow_form)
    |> assign(:workflow_setup_required, workflow_setup_required)
    |> assign(:project_configuration_items, ProjectSettings.scoped_configuration_items(configuration_items, "Project"))
    |> assign(:workflow_configuration_items, ProjectSettings.scoped_configuration_items(configuration_items, "Workflow"))
    |> assign(:runtime_configuration_items, ProjectSettings.scoped_configuration_items(configuration_items, "Runtime"))
    |> assign(:runtime_workflow_source, runtime_source_summary(runtime))
    |> assign(:db_runtime_mismatch, db_runtime_mismatch?(active, runtime))
    |> assign_detail_data()
  end

  defp refreshed_workflow_form(socket, loaded_workflow_form) do
    if Map.get(socket.assigns, :workflow_form_dirty?, false) do
      Map.get(socket.assigns, :workflow_form, loaded_workflow_form)
    else
      loaded_workflow_form
    end
  end

  defp nav_current(action) when action in [:settings, :settings_projects, :settings_workflow, :settings_agents, :settings_runtime, :settings_import], do: :settings
  defp nav_current(action), do: action

  defp settings_tab(:settings), do: :projects
  defp settings_tab(:settings_projects), do: :projects
  defp settings_tab(:settings_workflow), do: :workflow
  defp settings_tab(:settings_agents), do: :agents
  defp settings_tab(:settings_runtime), do: :runtime
  defp settings_tab(:settings_import), do: :import

  defp codex_approval_policy_options, do: Config.Schema.codex_approval_policies()

  defp default_project do
    case persistence().default_project() do
      {:ok, project} -> project
      _ -> nil
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

  defp assign_event_rows(socket) do
    filters = socket.assigns.event_filters

    rows =
      EventPresenter.rows(socket.assigns.events,
        hide_low_signal?: filters.hide_low_signal != "false",
        severity: blank_as_nil(filters.severity),
        source: blank_as_nil(filters.source)
      )

    socket
    |> assign(:event_rows, rows.visible)
    |> assign(:hidden_low_signal_event_count, rows.hidden_low_signal_count)
  end

  defp event_filters(%{assigns: %{route_params: params}}) do
    %{
      issue_identifier: Map.get(params, "issue_identifier", ""),
      run_id: Map.get(params, "run_id", ""),
      event_type: Map.get(params, "event_type", ""),
      severity: Map.get(params, "severity", ""),
      source: Map.get(params, "source", ""),
      hide_low_signal: Map.get(params, "hide_low_signal", "true"),
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
    SymphonyElixir.Text.blank_as_nil(value)
  end

  defp blank?(value), do: SymphonyElixir.Text.blankish?(value)

  defp assign_detail_data(%{assigns: %{live_action: :run_detail, route_params: %{"id" => id}}} = socket) do
    run = persistence().get_run(id)

    workflow_version =
      case run && Map.get(run, :workflow_version_id) do
        id when is_binary(id) -> persistence().get_workflow_version(id)
        _ -> nil
      end

    session_history = if(run, do: RunHistory.list_run_session_events(persistence(), run.id, limit: 100), else: [])

    assign(socket, :run_detail, %{
      run: run,
      workflow_version: workflow_version,
      turns: if(run, do: persistence().list_agent_turns_for_run(run.id), else: []),
      session_history: session_history,
      summary: RunHistory.summarize(run, session_history),
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
    |> assign_new(:run_detail, fn ->
      %{
        run: nil,
        workflow_version: nil,
        turns: [],
        session_history: [],
        summary: RunHistory.summarize(nil, []),
        events: []
      }
    end)
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

  defp maybe_update_project(id, attrs, socket) do
    case Enum.find(socket.assigns.projects, &(ProjectSettings.value(&1, :id) == id)) do
      nil ->
        persistence().update_project(id, attrs)

      project ->
        if ProjectSettings.changed?(project, attrs), do: persistence().update_project(id, attrs), else: :unchanged
    end
  end

  defp changeset_or_reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end

  defp changeset_or_reason(reason), do: inspect(reason)

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
    field_errors = WorkflowForm.field_errors(draft)

    if field_errors == %{},
      do: assign_workflow_semantic_validation(socket, draft),
      else: assign_workflow_field_validation(socket, draft, field_errors)
  end

  defp assign_workflow_field_validation(socket, draft, field_errors) do
    socket
    |> assign(:workflow_field_errors, field_errors)
    |> assign(:workflow_check_targets, [])
    |> assign(:workflow_validation_error, nil)
    |> assign(:workflow_form_valid?, false)
    |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
  end

  defp assign_workflow_semantic_validation(socket, draft) do
    with {:ok, raw} <- WorkflowForm.to_raw(draft),
         {:ok, _validation} <- WorkflowValidator.validate_raw(raw, runtime?: false) do
      socket
      |> assign(:workflow_field_errors, %{})
      |> assign(:workflow_check_targets, [])
      |> assign(:workflow_validation_error, nil)
      |> assign(:workflow_form_valid?, true)
      |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
    else
      {:error, {:workflow_validation_failed, message}} ->
        assign_workflow_semantic_error(socket, draft, message)

      {:error, message} ->
        assign_workflow_semantic_error(socket, draft, message)
    end
  end

  defp assign_workflow_semantic_error(socket, draft, message) do
    socket
    |> assign(:workflow_field_errors, %{})
    |> assign(:workflow_check_targets, SettingsCheck.workflow_check_targets(draft, message))
    |> assign(:workflow_validation_error, message)
    |> assign(:workflow_form_valid?, false)
    |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
  end

  defp settings_check_class(targets, tab, field, scope \\ nil, base \\ "settings-field") do
    SettingsCheck.class(targets, tab, field, scope, base)
  end

  defp settings_check_title_class(targets, tab, field, scope \\ nil, base \\ "metric-label") do
    SettingsCheck.title_class(targets, tab, field, scope, base)
  end

  defp settings_check_invalid?(targets, tab, field, scope \\ nil) do
    SettingsCheck.invalid?(targets, tab, field, scope)
  end

  defp settings_tab_label(:projects), do: "Projects"
  defp settings_tab_label(:workflow), do: "Workflow"
  defp settings_tab_label(:agents), do: "Agents"
  defp settings_tab_label(:runtime), do: "Runtime"
  defp settings_tab_label(:import), do: "Import"
  defp settings_tab_label(tab), do: to_string(tab)

  defp settings_tab_path(:projects), do: "/settings/projects"
  defp settings_tab_path(:workflow), do: "/settings/workflow"
  defp settings_tab_path(:agents), do: "/settings/agents"
  defp settings_tab_path(:runtime), do: "/settings/runtime"
  defp settings_tab_path(:import), do: "/settings/import"
  defp settings_tab_path(_tab), do: "/settings"

  defp project_field_class(items, title) do
    SettingsCheck.project_field_class(items, title)
  end

  defp project_field_title_class(items, title) do
    SettingsCheck.project_field_title_class(items, title)
  end

  defp workflow_field_id(field), do: "workflow-field-#{String.replace(field, "_", "-")}"

  defp workflow_field_class(errors, field) do
    if workflow_field_invalid?(errors, field), do: "field-invalid", else: nil
  end

  defp workflow_field_invalid?(errors, field), do: Map.has_key?(errors, field)

  defp workflow_field_label("polling_interval_ms"), do: "Polling interval ms"
  defp workflow_field_label("agent_max_concurrent_agents"), do: "Max agents"
  defp workflow_field_label("agent_max_turns"), do: "Max turns"
  defp workflow_field_label("hook_timeout_ms"), do: "Hook timeout ms"
  defp workflow_field_label("initialize_timeout_ms"), do: "Initialize timeout ms"
  defp workflow_field_label(field), do: field

  defp linear_workflow_state_check(draft, {:ok, discovery}) when is_map(draft) do
    with {:ok, raw} <- WorkflowForm.to_raw(draft),
         {:ok, %{settings: settings}} <- WorkflowValidator.validate_raw(raw, runtime?: false) do
      {:ok, WorkflowStateValidator.validate(settings, Map.get(discovery, :states, []))}
    else
      _ -> :unavailable
    end
  end

  defp linear_workflow_state_check(_draft, _discovery), do: :unavailable

  defp persistence, do: PersistenceProvider.module()

  defp import_upload_content(socket) do
    case uploaded_entries(socket, :settings_package) do
      {[_entry | _], _in_progress} ->
        socket
        |> consume_uploaded_entries(:settings_package, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)
        |> List.first()

      _entries ->
        nil
    end
  end

  defp import_source(socket, pasted) do
    case uploaded_entries(socket, :settings_package) do
      {[_entry | _], _in_progress} -> :upload
      _entries -> if blank?(pasted), do: :unknown, else: :paste
    end
  end

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

  defp workflow_change_status(raw, socket) do
    case Map.get(socket.assigns, :active_workflow_version) do
      nil ->
        :changed

      version ->
        current_raw = persistence().export_workflow(version)

        if WorkflowSettingsPackage.changed?(current_raw, raw), do: :changed, else: :unchanged
    end
  end

  defp assign_save_notice(socket, level, title, message) do
    assign(socket, :workflow_save_notice, %{
      level: level,
      title: title,
      message: message
    })
  end

  defp assign_import_notice(socket, level, title, message) do
    assign(socket, :workflow_import_notice, %{
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

  defp profile_prompt_page_summary(form) do
    ProfilePromptSummary.page_summary(Map.get(form, "prompt_body", ""), Map.get(form, "profiles", %{}))
  end

  defp profile_prompt_summary(form, profile_id, profile) do
    ProfilePromptSummary.profile_summary(Map.get(form, "prompt_body", ""), profile_id, profile)
  end

  defp format_prompt_chars(nil), do: "n/a"
  defp format_prompt_chars(chars), do: "#{chars}"

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

  defp fmt_dt(value), do: ObservabilityPresenter.fmt_dt(value)

  defp fmt_duration(started_at, finished_at), do: ObservabilityPresenter.fmt_duration(started_at, finished_at)

  defp list_summary([]), do: "n/a"
  defp list_summary(values) when is_list(values), do: Enum.join(values, " | ")

  defp workflow_version_summary(version), do: ObservabilityPresenter.workflow_version_summary(version)

  defp safe_event_payload(payload), do: ObservabilityPresenter.safe_event_payload(payload)

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "\n... truncated"
  end

  defp truncate(value, _limit), do: value

  defp status_class(status), do: ObservabilityPresenter.status_class(status)
end
