defmodule SymphonyElixirWeb.AdminLive.SettingsShell do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixir.Linear.Discovery
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter
  alias SymphonyElixirWeb.Admin.SettingsCheck
  alias SymphonyElixirWeb.AdminLive.Settings.{Agents, Import, Projects, Runtime, Workflow}

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assign(assigns, :settings_tab, tab(assigns.live_action))

    ~H"""
    <section class="section-card settings-header-card">
      <div class="section-header">
        <div>
          <h1 class="section-title">Settings</h1>
          <p class="metric-label">Configure projects, workflow routing, agent profiles, and runtime settings.</p>
        </div>
        <SymphonyElixirWeb.Layouts.project_switcher
          projects={@projects}
          current={@event_filters.project_id}
          base_path={path(@settings_tab)}
        />
      </div>
      <.settings_tabs active={@settings_tab} project={@event_filters.project_id} />
    </section>

    <.linear_discovery_panel
      :if={@settings_tab in [:projects, :workflow]}
      status={@linear_discovery_status}
      discovery={@linear_discovery}
      message={@linear_discovery_message}
    />

    {page(@settings_tab, assigns)}
    """
  end

  @spec fetch_linear_discovery(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def fetch_linear_discovery(socket) do
    case Discovery.fetch() do
      {:ok, discovery} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:ok, discovery})
         |> assign(:linear_discovery_status, :fetched)
         |> assign(:linear_discovery_message, "Fetched at #{ObservabilityPresenter.fmt_dt(discovery.fetched_at)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:linear_discovery, {:error, reason})
         |> assign(:linear_discovery_status, :failed)
         |> assign(:linear_discovery_message, "Linear configuration fetch failed: #{inspect(reason)}")}
    end
  end

  @spec tab(atom()) :: :agents | :import | :projects | :runtime | :workflow
  def tab(:settings), do: :projects
  def tab(:settings_projects), do: :projects
  def tab(:settings_workflow), do: :workflow
  def tab(:settings_agents), do: :agents
  def tab(:settings_runtime), do: :runtime
  def tab(:settings_import), do: :import

  @spec label(atom()) :: String.t()
  def label(:projects), do: "Projects"
  def label(:workflow), do: "Workflow"
  def label(:agents), do: "Agents"
  def label(:runtime), do: "Runtime"
  def label(:import), do: "Import"
  def label(tab), do: to_string(tab)

  @spec path(atom()) :: String.t()
  def path(:projects), do: "/settings/projects"
  def path(:workflow), do: "/settings/workflow"
  def path(:agents), do: "/settings/agents"
  def path(:runtime), do: "/settings/runtime"
  def path(:import), do: "/settings/import"
  def path(_tab), do: "/settings"

  attr(:active, :atom, required: true)
  attr(:project, :any, default: nil)

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
        patch={settings_tab_link(path, @project)}
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
            <span class="status-badge status-danger"><%= label(target.tab) %></span>
            <strong><%= target.title %></strong>
          </div>
          <span><%= target.message %></span>
          <a :if={target.tab != @current_tab} class="issue-link" href={path(target.tab)}>Open <%= label(target.tab) %></a>
        </li>
      </ul>
    </aside>
    """
  end

  defp page(:projects, assigns), do: Projects.render(assigns)
  defp page(:workflow, assigns), do: Workflow.render(assigns)
  defp page(:agents, assigns), do: Agents.render(assigns)
  defp page(:runtime, assigns), do: Runtime.render(assigns)
  defp page(:import, assigns), do: Import.render(assigns)

  defp settings_tab_link(path, nil), do: path
  defp settings_tab_link(path, project_id), do: "#{path}?project=#{project_id}"
end
