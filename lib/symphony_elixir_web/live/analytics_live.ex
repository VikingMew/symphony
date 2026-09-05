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

      <%= if @summary.status == :unavailable do %>
        <section class="error-card" role="status">
          <h2 class="error-title">Data unavailable</h2>
          <p class="error-copy">Persisted analytics data could not be loaded. Please retry after database access is restored.</p>
        </section>
      <% else %>
        <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Runs</p>
          <p class="metric-value numeric"><%= int(@summary.total_runs) %></p>
          <p class="metric-detail">Persisted runs in range</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Refinement description</p>
          <p class="metric-value numeric"><%= int(@summary.refinement_description.samples) %> samples</p>
          <p class="metric-detail">Avg <%= Float.round(@summary.refinement_description.average_characters, 1) %> chars / <%= Float.round(@summary.refinement_description.average_lines, 1) %> lines; p95 <%= @summary.refinement_description.p95_characters %> / <%= @summary.refinement_description.p95_lines %>; over limit <%= @summary.refinement_description.over_limit %> (<%= Float.round(@summary.refinement_description.over_rate * 100, 1) %>%)</p>
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

          <section class="section-card">
            <h2 class="section-title">Issue-flow quality</h2>
            <p class="section-copy">Derived from persisted issue runs and events in the selected range.</p>
            <div class="metric-grid">
              <article class={["metric-card", warning_class(@summary.issue_quality.refinement.warning)]}>
                <p class="metric-label">Refinement rounds</p>
                <p class="metric-value numeric"><%= number(@summary.issue_quality.refinement.average) %></p>
                <p class="metric-detail">0: <%= @summary.issue_quality.refinement.distribution.zero %> · 1: <%= @summary.issue_quality.refinement.distribution.one %> · 2: <%= @summary.issue_quality.refinement.distribution.two %> · 3+: <%= @summary.issue_quality.refinement.distribution.three_plus %>; <%= @summary.issue_quality.refinement.denominator %> issues</p>
              </article>
              <article class={["metric-card", warning_class(@summary.issue_quality.review_return.warning)]}>
                <p class="metric-label">First-handoff observed-return proxy</p>
                <p class="metric-value numeric"><%= ratio(@summary.issue_quality.review_return) %></p>
                <p class="metric-detail"><%= @summary.issue_quality.review_return.pending_censored %> pending/censored. Workflow transitions only; not GitHub review/check outcomes.</p>
              </article>
              <article class={["metric-card", warning_class(@summary.issue_quality.blocked.warning)]}>
                <p class="metric-label">Blocked issue rate</p>
                <p class="metric-value numeric"><%= ratio(@summary.issue_quality.blocked) %></p>
                <p class="metric-detail">Unique issues with a run in range.</p>
              </article>
              <article class={["metric-card", warning_class(@summary.issue_quality.description.warning)]}>
                <p class="metric-label">Latest description length</p>
                <p class="metric-value numeric"><%= number(@summary.issue_quality.description.average) %></p>
                <p class="metric-detail">p50 <%= number(@summary.issue_quality.description.p50) %>; <%= @summary.issue_quality.description.missing %> missing. Latest observed snapshot, not creation-time length.</p>
              </article>
              <article class={["metric-card", warning_class(@summary.issue_quality.rework.warning)]}>
                <p class="metric-label">Implementation rework proxy</p>
                <p class="metric-value numeric"><%= ratio(@summary.issue_quality.rework) %></p>
                <p class="metric-detail">Return transition or repeated handoff; does not infer diff size.</p>
              </article>
              <article class="metric-card">
                <p class="metric-label">Issue origin coverage</p>
                <p class="metric-value numeric"><%= @summary.issue_quality.origin.agent_created %>/<%= @summary.issue_quality.origin.denominator %></p>
                <p class="metric-detail"><%= @summary.issue_quality.origin.external_unknown %> external/unknown. <%= if @summary.issue_quality.origin.status == :insufficient_coverage, do: "Unavailable / insufficient creator audit coverage.", else: "Agent-created evidence available." %></p>
              </article>
            </div>
            <h3 class="section-title">Token usage by profile and issue</h3>
            <p class="section-copy">Canonical cumulative snapshots; maximum absolute snapshot per run. No rate-limit percentages or monetary cost.</p>
            <div class="table-wrap"><table class="data-table analytics-table"><thead><tr><th>Profile</th><th>Issue</th><th>Input</th><th>Output</th><th>Total</th></tr></thead><tbody>
              <tr :for={row <- @summary.issue_quality.token_rows} class={warning_class(row.warning)}><td><%= row.profile %></td><td><%= row.issue_identifier %></td><td class="numeric"><%= row.tokens.input_tokens %></td><td class="numeric"><%= row.tokens.output_tokens %></td><td class="numeric"><%= row.tokens.total_tokens %></td></tr>
            </tbody></table></div>
          </section>
        <% end %>
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
  defp number(nil), do: "Unavailable"
  defp number(value) when is_float(value), do: value |> Float.round(2) |> to_string()
  defp number(value), do: to_string(value)
  defp ratio(%{denominator: 0}), do: "Unavailable"
  defp ratio(metric), do: "#{metric.numerator}/#{metric.denominator} (#{number(metric.rate * 100)}%)"
  defp warning_class(true), do: "status-warning"
  defp warning_class(false), do: nil

  defp duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
  end

  defp duration(seconds) when is_integer(seconds) and seconds >= 60, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp duration(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp duration(_seconds), do: "0s"

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_dt), do: "n/a"
end
