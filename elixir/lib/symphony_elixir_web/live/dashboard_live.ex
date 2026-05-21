defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:expanded_session_histories, MapSet.new())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("toggle_session_history", %{"key" => key}, socket) when is_binary(key) do
    expanded_session_histories =
      socket.assigns.expanded_session_histories
      |> toggle_session_history_key(key)

    {:noreply, assign(socket, :expanded_session_histories, expanded_session_histories)}
  end

  @impl true
  def handle_event("start_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.start_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening started: #{inspect(result)}")
     |> refresh_payload()}
  end

  @impl true
  def handle_event("stop_listening", _params, socket) do
    result = SymphonyElixir.Orchestrator.stop_listening(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Listening stopped: #{inspect(result)}")
     |> refresh_payload()}
  end

  @impl true
  def handle_event("force_stop_all", _params, socket) do
    result = SymphonyElixir.Orchestrator.force_stop_all(orchestrator())

    {:noreply,
     socket
     |> put_flash(:info, "Force stop requested: #{inspect(result)}")
     |> refresh_payload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={:dashboard} />

      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Runtime controls</h2>
              <p class="metric-label">
                Listening:
                <span class={listening_badge_class(@payload)}>
                  <%= if listening_enabled?(@payload), do: "enabled", else: "disabled" %>
                </span>
              </p>
            </div>
            <div class="button-row">
              <button class="subtle-button" phx-click="start_listening">Start listening</button>
              <button class="subtle-button" phx-click="stop_listening">Stop listening</button>
              <button
                class="subtle-button"
                phx-click="force_stop_all"
                data-confirm="Force stop all active agents and roll back Symphony-owned Linear state transitions when safe?"
              >Force stop all agents</button>
            </div>
          </div>
        </section>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <a class="metric-card dashboard-signal-card" href={@payload.linear_status.href}>
            <span class={@payload.linear_status.badge_class}><%= @payload.linear_status.label %></span>
            <p class="metric-detail"><%= @payload.linear_status.detail %></p>
            <p class="metric-detail">
              Project <span class="mono"><%= @payload.linear_status.project_slug || "n/a" %></span>
              <%= if @payload.linear_status.ran_at do %>
                · <span class="mono numeric"><%= format_time(@payload.linear_status.ran_at) %></span>
              <% else %>
                · open diagnostics
              <% end %>
            </p>
          </a>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy"><%= @payload.rate_limit_status.note %></p>
            </div>
            <span class={rate_limit_badge_class(@payload.rate_limit_status.status)}>
              <%= rate_limit_status_label(@payload.rate_limit_status.status) %>
            </span>
          </div>

          <%= if @payload.rate_limit_status.status == :available do %>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limit_status.snapshot) %></pre>
          <% else %>
            <div class="rate-limit-fallback-grid">
              <article class="metric-card">
                <p class="metric-label">Token totals</p>
                <p class="metric-detail numeric">
                  Total <%= format_int(@payload.rate_limit_status.token_totals.total_tokens) %>
                  · In <%= format_int(@payload.rate_limit_status.token_totals.input_tokens) %>
                  · Out <%= format_int(@payload.rate_limit_status.token_totals.output_tokens) %>
                </p>
              </article>
              <article class="metric-card">
                <p class="metric-label">Codex evidence</p>
                <p class="metric-detail">
                  Last event <span class="mono"><%= @payload.rate_limit_status.last_codex_event || "n/a" %></span>
                </p>
                <p class="metric-detail">
                  <%= @payload.rate_limit_status.last_codex_message || "No Codex update message observed." %>
                </p>
                <p class="metric-detail mono numeric"><%= @payload.rate_limit_status.last_codex_timestamp || "n/a" %></p>
              </article>
              <article class="metric-card">
                <p class="metric-label">Active sessions</p>
                <p class="metric-value numeric"><%= @payload.rate_limit_status.active_sessions %></p>
                <p class="metric-detail">Running sessions that may produce future Codex updates.</p>
              </article>
            </div>
            <details :if={@payload.rate_limit_status.status == :unrecognized and @payload.rate_limit_status.debug_payload} class="rate-limit-debug-panel">
              <summary>Raw rate-limit payload</summary>
              <div class="rate-limit-debug-meta">
                <span>Source <code><%= rate_limit_debug_source(@payload.rate_limit_status.debug_payload) %></code></span>
                <span>Method <code><%= rate_limit_debug_method(@payload.rate_limit_status.debug_payload) %></code></span>
                <span :if={rate_limit_debug_truncated?(@payload.rate_limit_status.debug_payload)} class="status-badge status-warning">truncated</span>
              </div>
              <p class="metric-detail"><%= rate_limit_debug_reason(@payload.rate_limit_status.debug_payload) %></p>
              <pre class="code-panel"><%= rate_limit_debug_payload(@payload.rate_limit_status.debug_payload) %></pre>
            </details>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody :for={entry <- @payload.running}>
                  <tr>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                  <tr class="session-history-row">
                    <td colspan="6">
                      <details open={session_history_expanded?(@expanded_session_histories, entry)}>
                        <summary
                          phx-click="toggle_session_history"
                          phx-value-key={session_history_key(entry)}
                        ><%= session_history_summary(entry) %></summary>
                        <%= if (entry.session_history || []) == [] do %>
                          <p class="empty-state">No session history recorded.</p>
                        <% else %>
                          <ol class="session-history-list">
                            <li :for={event <- entry.session_history}>
                              <span class={history_source_badge_class(Map.get(event, :source))}><%= history_source_label(Map.get(event, :source)) %></span>
                              <span class={history_badge_class(event.severity)}><%= event.label %></span>
                              <span class="mono numeric"><%= event.at || "n/a" %></span>
                              <span class="muted"><%= event.detail || to_string(event.event || "") %></span>
                            </li>
                          </ol>
                        <% end %>
                      </details>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp refresh_payload(socket) do
    socket
    |> assign(:payload, load_payload())
    |> assign(:now, DateTime.utc_now())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_time(value), do: to_string(value)

  defp rate_limit_status_label(:available), do: "available"
  defp rate_limit_status_label(:unrecognized), do: "unrecognized"
  defp rate_limit_status_label(_status), do: "not received"

  defp rate_limit_badge_class(:available), do: "status-badge status-success"
  defp rate_limit_badge_class(:unrecognized), do: "status-badge status-warning"
  defp rate_limit_badge_class(_status), do: "status-badge status-info"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp listening_enabled?(payload) do
    payload
    |> Map.get(:polling, %{})
    |> Map.get(:listening?, false)
  end

  defp listening_badge_class(payload) do
    if listening_enabled?(payload), do: "status-badge status-success", else: "status-badge status-danger"
  end

  defp history_badge_class(:error), do: "status-badge status-danger"
  defp history_badge_class(:warning), do: "status-badge status-warning"
  defp history_badge_class(_severity), do: "status-badge status-info"

  defp history_source_badge_class(:system), do: "status-badge"
  defp history_source_badge_class("system"), do: "status-badge"
  defp history_source_badge_class(:linear), do: "status-badge status-accent"
  defp history_source_badge_class("linear"), do: "status-badge status-accent"
  defp history_source_badge_class(_source), do: "status-badge status-info"

  defp history_source_label(nil), do: "agent"
  defp history_source_label(source), do: source |> to_string() |> String.replace("_", " ")

  defp session_history_key(entry) do
    cond do
      Map.get(entry, :issue_id) not in [nil, ""] -> Map.get(entry, :issue_id)
      Map.get(entry, :issue_identifier) not in [nil, ""] -> Map.get(entry, :issue_identifier)
      true -> Map.get(entry, :session_id) || "unknown"
    end
  end

  defp session_history_expanded?(expanded_session_histories, entry) do
    MapSet.member?(expanded_session_histories, session_history_key(entry))
  end

  defp session_history_summary(entry) do
    visible_count = length(Map.get(entry, :session_history, []) || [])
    total_count = Map.get(entry, :session_history_total_count) || visible_count

    if total_count > visible_count do
      "Session history (#{visible_count} rows from #{total_count} events)"
    else
      "Session history (#{visible_count})"
    end
  end

  defp toggle_session_history_key(expanded_session_histories, key) do
    if MapSet.member?(expanded_session_histories, key) do
      MapSet.delete(expanded_session_histories, key)
    else
      MapSet.put(expanded_session_histories, key)
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp rate_limit_debug_source(debug), do: debug_value(debug, :source_path, "n/a")
  defp rate_limit_debug_method(debug), do: debug_value(debug, :method, "n/a")
  defp rate_limit_debug_reason(debug), do: debug_value(debug, :reason, "No parser failure reason recorded.")
  defp rate_limit_debug_truncated?(debug), do: debug_value(debug, :truncated, false) == true

  defp rate_limit_debug_payload(debug) do
    debug
    |> debug_value(:payload, nil)
    |> pretty_value()
    |> truncate_string(2_000)
  end

  defp debug_value(debug, key, default) when is_map(debug), do: Map.get(debug, key) || Map.get(debug, to_string(key)) || default
  defp debug_value(_debug, _key, default), do: default

  defp truncate_string(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes,
    do: binary_part(value, 0, max_bytes) <> "... (truncated)"

  defp truncate_string(value, _max_bytes), do: value
end
