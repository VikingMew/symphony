defmodule SymphonyElixirWeb.AnalyticsLive do
  @moduledoc """
  Historical runtime analytics page backed by persisted records.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Analytics

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign_summary(socket, params)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_summary(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={:analytics} />

      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Historical Results</p>
            <h1 class="hero-title">Analytics</h1>
            <p class="hero-copy">
              Persisted run outcomes, retries, blocked sessions, durations, token usage, and project progress for the selected time range.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-info"><%= @summary.range.label %></span>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Time Range</h2>
            <p class="section-copy">
              Generated at <span class="mono"><%= fmt_dt(@summary.generated_at) %></span>.
            </p>
          </div>

          <nav class="range-nav" aria-label="Analytics range">
            <a
              :for={{preset, label} <- @range_presets}
              class={["pill-link", if(preset == @summary.range.preset, do: "pill-link-active")]}
              href={"/analytics?range=#{preset}"}
            >
              <%= label %>
            </a>
          </nav>
        </div>
      </section>

      <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Runs</p>
          <p class="metric-value numeric"><%= int(@summary.total_runs) %></p>
          <p class="metric-detail">Persisted runs in range</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Retries</p>
          <p class="metric-value numeric"><%= int(@summary.retry_count) %></p>
          <p class="metric-detail">Retry events in range</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Blocked</p>
          <p class="metric-value numeric"><%= int(@summary.blocked_count) %></p>
          <p class="metric-detail">Blocked runs or events</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Total tokens</p>
          <p class="metric-value numeric"><%= int(@summary.tokens.total_tokens) %></p>
          <p class="metric-detail">
            In <%= int(@summary.tokens.input_tokens) %> / Out <%= int(@summary.tokens.output_tokens) %>
          </p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Average duration</p>
          <p class="metric-value numeric"><%= duration(@summary.duration.average_seconds) %></p>
          <p class="metric-detail">
            p50 <%= duration(@summary.duration.p50_seconds) %> / p95 <%= duration(@summary.duration.p95_seconds) %>
          </p>
        </article>
      </section>

      <%= if @summary.total_runs == 0 and @summary.event_rows == [] do %>
        <section class="section-card">
          <p class="empty-state">No persisted analytics data for this range.</p>
        </section>
      <% else %>
        <section class="analytics-grid">
          <.breakdown title="Status" rows={@summary.status_rows} show_status_columns={false} />
          <.breakdown title="Projects" rows={@summary.project_rows} />
          <.breakdown title="Issues" rows={@summary.issue_rows} />
          <.breakdown title="Execution Mode" rows={@summary.execution_mode_rows} />
          <.breakdown title="Failures" rows={@summary.failure_rows} />
          <.breakdown title="Events" rows={@summary.event_rows} />
        </section>
      <% end %>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:show_status_columns, :boolean, default: true)

  defp breakdown(assigns) do
    ~H"""
    <section class="section-card">
      <h2 class="section-title"><%= @title %></h2>

      <%= if @rows == [] do %>
        <p class="empty-state">No rows.</p>
      <% else %>
        <div class="table-wrap">
          <table class="data-table analytics-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Runs</th>
                <th :if={@show_status_columns}>Completed</th>
                <th :if={@show_status_columns}>Failed</th>
                <th :if={@show_status_columns}>Blocked</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td><a class="issue-link" href={row.href}><%= row.key %></a></td>
                <td class="numeric"><%= row.count %></td>
                <td :if={@show_status_columns} class="numeric"><%= Map.get(row, :completed, 0) %></td>
                <td :if={@show_status_columns} class="numeric"><%= Map.get(row, :failed, 0) %></td>
                <td :if={@show_status_columns} class="numeric"><%= Map.get(row, :blocked, 0) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  defp assign_summary(socket, params) do
    range = Map.get(params, "range", "7d")

    socket
    |> assign(:range_presets, Analytics.range_presets())
    |> assign(:summary, Analytics.summary(range: range))
  end

  defp int(value) when is_integer(value), do: Integer.to_string(value)
  defp int(_value), do: "0"

  defp duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  end

  defp duration(seconds) when is_integer(seconds) and seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp duration(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp duration(_seconds), do: "0s"

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_dt), do: "n/a"
end
