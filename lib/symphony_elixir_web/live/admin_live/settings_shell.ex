defmodule SymphonyElixirWeb.AdminLive.SettingsShell do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.Settings.Components,
    only: [path: 1, settings_tabs: 1, tab: 1]

  alias SymphonyElixir.Linear.Discovery
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter
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

    <aside :if={@persistence_error} class="error-card" role="status">
      <h2 class="error-title">Data unavailable</h2>
      <p class="error-copy">Persisted project and workflow data could not be loaded. Please retry after database access is restored.</p>
    </aside>

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

  defp page(:projects, assigns), do: Projects.render(assigns)
  defp page(:workflow, assigns), do: Workflow.render(assigns)
  defp page(:agents, assigns), do: Agents.render(assigns)
  defp page(:runtime, assigns), do: Runtime.render(assigns)
  defp page(:import, assigns), do: Import.render(assigns)
end
