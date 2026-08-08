defmodule SymphonyElixirWeb.AdminLive.Events do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixir.{EventPresenter, PersistenceProvider}
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
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
        <label>
          <span class="metric-label">Project</span>
          <select name="project">
            <option value="" selected={is_nil(@event_filters.project_id)}>all</option>
            <option
              :for={project <- @projects}
              value={project.id}
              selected={@event_filters.project_id == project.id}
            >
              <%= project.name %>
            </option>
          </select>
        </label>
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

      <%= if @events_error || @persistence_error do %>
        <div class="error-card" role="status">
          <h2 class="error-title">Data unavailable</h2>
          <p class="error-copy">Persisted events could not be loaded. Please retry after database access is restored.</p>
        </div>
      <% else %>
      <%= if @event_rows == [] do %>
        <p class="empty-state">No events recorded.</p>
      <% else %>
        <table class="data-table events-table">
          <thead><tr><th>Time</th><th>Issue</th><th>Run</th><th>Source</th><th>Severity</th><th>Type</th><th>Summary</th><th>Raw</th></tr></thead>
          <tbody>
            <tr :for={event <- @event_rows}>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(event.occurred_at) %></td>
              <td>
                <a :if={event.issue_identifier} class="issue-link" href={"/issues/#{event.issue_identifier}"}><%= event.issue_identifier %></a>
                <span :if={is_nil(event.issue_identifier)} class="muted">n/a</span>
              </td>
              <td>
                <a :if={event.run_id} class="issue-link mono" href={"/runs/#{event.run_id}"}><%= event.run_id %></a>
                <span :if={is_nil(event.run_id)} class="muted">n/a</span>
              </td>
              <td><span class="status-badge status-info"><%= event.source %></span></td>
              <td><span class={ObservabilityPresenter.status_class(to_string(event.severity))}><%= event.severity %></span></td>
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
                  <pre class="inline-code-panel"><%= ObservabilityPresenter.safe_event_payload(event.raw_payload) %></pre>
                </details>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
      <% end %>
    </section>
    """
  end

  @spec assign_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_data(socket) do
    filters = filters(socket)

    events_result =
      PersistenceProvider.read(fn ->
        persistence().list_events(
          issue_identifier: blank_as_nil(filters.issue_identifier),
          run_id: blank_as_nil(filters.run_id),
          event_type: blank_as_nil(filters.event_type),
          project_id: filters.project_id,
          limit: filters.limit
        )
      end)

    {events, events_error} =
      case events_result do
        events when is_list(events) -> {events, nil}
        {:error, reason} -> {[], reason}
      end

    rows =
      EventPresenter.rows(events,
        hide_low_signal?: filters.hide_low_signal != "false",
        severity: blank_as_nil(filters.severity),
        source: blank_as_nil(filters.source)
      )

    socket
    |> assign(:events, events)
    |> assign(:events_error, events_error)
    |> assign(:event_filters, filters)
    |> assign(:event_rows, rows.visible)
    |> assign(:hidden_low_signal_event_count, rows.hidden_low_signal_count)
  end

  @spec filters(Phoenix.LiveView.Socket.t()) :: map()
  def filters(%{assigns: %{route_params: params}}) do
    %{
      project_id: blank_as_nil(Map.get(params, "project", "")),
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

  defp blank_as_nil(value), do: SymphonyElixir.Text.blank_as_nil(value)
  defp persistence, do: PersistenceProvider.module()
end
