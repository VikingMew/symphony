defmodule SymphonyElixirWeb.LinearDiagnosticsLive do
  @moduledoc """
  Linear integration diagnostics page.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Linear.Diagnostics, Linear.Discovery, Linear.WorkflowBootstrap}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:refresh_message, nil)
     |> assign(:bootstrap_result, nil)
     |> assign(:discovery, nil)
     |> assign(:diagnostics, Diagnostics.run())}
  end

  @impl true
  def handle_event("refresh_diagnostics", _params, socket) do
    diagnostics = Diagnostics.run()

    {:noreply,
     socket
     |> assign(:diagnostics, diagnostics)
     |> assign(:bootstrap_result, nil)
     |> assign(:refresh_message, "Diagnostics refreshed at #{fmt_dt(diagnostics.ran_at)}")}
  end

  @impl true
  def handle_event("fetch_linear_discovery", _params, socket) do
    case Discovery.fetch() do
      {:ok, discovery} ->
        {:noreply,
         socket
         |> assign(:discovery, {:ok, discovery})
         |> assign(:refresh_message, "Linear configuration fetched at #{fmt_dt(discovery.fetched_at)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:discovery, {:error, reason})
         |> assign(:refresh_message, "Linear configuration fetch failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("bootstrap_linear_statuses", _params, socket) do
    diagnostics = socket.assigns.diagnostics

    result =
      WorkflowBootstrap.create_missing_statuses(
        Config.settings!(),
        get_in(diagnostics, [:probes, :states, :data, :available]) || [],
        get_in(diagnostics, [:probes, :project, :data]) || %{}
      )

    refreshed = Diagnostics.run()

    message =
      case result do
        {:ok, %{created: created, skipped: skipped, failed: []}} ->
          "Linear statuses updated. Created: #{list_text(created)}. Skipped: #{list_text(skipped)}."

        {:ok, %{created: created, skipped: skipped, failed: failed}} ->
          "Linear status bootstrap partially failed. Created: #{list_text(created)}. Skipped: #{list_text(skipped)}. Failed: #{failed_text(failed)}."

        {:error, reason} ->
          "Linear status bootstrap failed: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> assign(:diagnostics, refreshed)
     |> assign(:bootstrap_result, result)
     |> assign(:refresh_message, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <SymphonyElixirWeb.Layouts.app_nav current={:linear} />

      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Linear Diagnostics</p>
            <h1 class="hero-title">Linear</h1>
            <p class="hero-copy">
              Validate Linear API connectivity, project configuration, workflow states, and candidate issue discovery.
            </p>
          </div>
          <div class="status-stack">
            <button type="button" class="subtle-button" phx-click="refresh_diagnostics">Refresh</button>
            <button type="button" class="subtle-button" phx-click="fetch_linear_discovery">Fetch Linear configuration</button>
          </div>
        </div>
      </header>

      <p :if={@refresh_message} class="empty-state">{@refresh_message}</p>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Linear Configuration Discovery</h2>
            <p class="section-copy">Fetch read-only Linear projects, teams, and workflow states to copy into Symphony settings.</p>
          </div>
          <button type="button" class="subtle-button" phx-click="fetch_linear_discovery">Fetch Linear configuration</button>
        </div>

        <%= case @discovery do %>
          <% nil -> %>
            <p class="empty-state">No discovery data fetched yet.</p>
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
                <h3 class="diagnostics-subtitle">Projects</h3>
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

      <section :if={bootstrap_missing_states(@diagnostics) != []} class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Linear Status Bootstrap</h2>
            <p class="section-copy">Create the missing Linear workflow statuses required by the active Symphony workflow.</p>
          </div>
          <button
            type="button"
            class="subtle-button"
            phx-click="bootstrap_linear_statuses"
            data-confirm="This will create missing workflow statuses in the configured Linear team. Continue?"
            disabled={not bootstrap_available?(@diagnostics)}
          >
            Create missing Linear statuses
          </button>
        </div>

        <p class="metric-detail">
          Missing statuses: <span class="mono">{Enum.join(bootstrap_missing_states(@diagnostics), ", ")}</span>
        </p>
        <p :if={not bootstrap_available?(@diagnostics)} class="empty-state">
          Bootstrap is unavailable until Linear API access and project team resolution succeed.
        </p>
      </section>

      <section class="metric-grid">
        <article class="metric-card">
          <span class="status-badge status-info">Run</span>
          <p class="metric-label">Last run</p>
          <p class="metric-detail mono">{fmt_dt(@diagnostics.ran_at)}</p>
        </article>
        <article class="metric-card">
          <span class="status-badge status-info">ID</span>
          <p class="metric-label">Run ID</p>
          <p class="metric-detail mono">{@diagnostics.run_id}</p>
        </article>
        <article class="metric-card">
          <span class="status-badge status-info">Runtime</span>
          <p class="metric-label">Workflow source</p>
          <p class="metric-detail">
            {@diagnostics.runtime_source.type}
            <span class="mono"><%= @diagnostics.runtime_source.detail %></span>
          </p>
        </article>
        <article :for={probe <- probe_list(@diagnostics)} class="metric-card">
          <span class={probe_badge_class(probe.status)}>{probe_status_text(probe.status)}</span>
          <p class="metric-label">{probe.title}</p>
          <p class="metric-detail">{probe.detail}</p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Tracker Configuration</h2>
            <p class="section-copy">Current active workflow tracker settings used by diagnostics.</p>
          </div>
        </div>

        <div class="table-wrap">
          <table class="data-table diagnostics-table">
            <tbody>
              <tr>
                <th>Kind</th>
                <td>{@diagnostics.config.tracker_kind}</td>
              </tr>
              <tr>
                <th>Endpoint</th>
                <td class="mono">{@diagnostics.config.endpoint}</td>
              </tr>
              <tr>
                <th>Project slug</th>
                <td>{@diagnostics.config.project_slug}</td>
              </tr>
              <tr>
                <th>Assignee</th>
                <td>{@diagnostics.config.assignee}</td>
              </tr>
              <tr>
                <th>API token</th>
                <td>{if @diagnostics.config.token_configured, do: "configured", else: "missing"}</td>
              </tr>
              <tr>
                <th>Token source</th>
                <td>{@diagnostics.config.token.source}</td>
              </tr>
              <tr>
                <th>Token length</th>
                <td>{@diagnostics.config.token.length}</td>
              </tr>
              <tr>
                <th>Token fingerprint</th>
                <td class="mono">{@diagnostics.config.token.sha256_prefix}</td>
              </tr>
              <tr>
                <th>Active states</th>
                <td>{Enum.join(@diagnostics.config.active_states, ", ")}</td>
              </tr>
              <tr>
                <th>Terminal states</th>
                <td>{Enum.join(@diagnostics.config.terminal_states, ", ")}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Diagnostics Log</h2>
            <p class="section-copy">Step-by-step result from the latest Linear diagnostics run.</p>
          </div>
        </div>

        <div class="table-wrap">
          <table class="data-table diagnostics-log-table">
            <thead>
              <tr>
                <th>Step</th>
                <th>Status</th>
                <th>Message</th>
                <th>Metadata</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @diagnostics.log}>
                <td class="mono">{entry.step}</td>
                <td><span class={probe_badge_class(entry.status)}>{probe_status_text(entry.status)}</span></td>
                <td>{entry.message}</td>
                <td><pre class="inline-code-panel">{pretty_value(entry.metadata)}</pre></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Account, Teams, and Project</h2>
            <p class="section-copy">Authenticated Linear account, visible teams, resolved project metadata, and configured state coverage.</p>
          </div>
        </div>

        <div class="diagnostics-grid">
          <div>
            <h3 class="diagnostics-subtitle">Account</h3>
            <pre class="code-panel">{pretty_value(account_data(@diagnostics))}</pre>
          </div>
          <div>
            <h3 class="diagnostics-subtitle">Teams</h3>
            <pre class="code-panel">{pretty_value(teams_data(@diagnostics))}</pre>
          </div>
          <div>
            <h3 class="diagnostics-subtitle">Project</h3>
            <pre class="code-panel">{pretty_value(project_data(@diagnostics))}</pre>
          </div>
          <div>
            <h3 class="diagnostics-subtitle">States</h3>
            <pre class="code-panel">{pretty_value(states_data(@diagnostics))}</pre>
          </div>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Candidate Issues</h2>
            <p class="section-copy">Issues returned by the same candidate discovery path used by runtime polling.</p>
          </div>
        </div>

        <%= if @diagnostics.issues == [] do %>
          <p class="empty-state">No candidate issues returned.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Title</th>
                  <th>State</th>
                  <th>Assignee</th>
                  <th>Labels</th>
                  <th>Blockers</th>
                  <th>Updated</th>
                  <th>URL</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={issue <- @diagnostics.issues}>
                  <td class="issue-id">{issue.identifier}</td>
                  <td>{issue.title}</td>
                  <td><span class="status-badge status-info">{issue.state}</span></td>
                  <td>{issue.assignee}</td>
                  <td>{Enum.join(issue.labels, ", ")}</td>
                  <td>{blockers_text(issue.blockers)}</td>
                  <td class="mono">{issue.updated_at}</td>
                  <td>
                    <a :if={issue.url != "n/a"} class="issue-link" href={issue.url}>Open</a>
                    <span :if={issue.url == "n/a"} class="muted">n/a</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp probe_list(diagnostics) do
    [
      diagnostics.probes.api,
      diagnostics.probes.teams,
      diagnostics.probes.project,
      diagnostics.probes.states,
      diagnostics.probes.candidates
    ]
  end

  defp probe_badge_class(:ok), do: "status-badge status-success"
  defp probe_badge_class(:warning), do: "status-badge status-warning"
  defp probe_badge_class(:error), do: "status-badge status-danger"
  defp probe_badge_class(:skipped), do: "status-badge"
  defp probe_badge_class(_status), do: "status-badge"

  defp probe_status_text(:ok), do: "Healthy"
  defp probe_status_text(:warning), do: "Warning"
  defp probe_status_text(:error), do: "Failed"
  defp probe_status_text(:skipped), do: "Skipped"
  defp probe_status_text(_status), do: "Unknown"

  defp project_data(diagnostics) do
    get_in(diagnostics, [:probes, :project, :data]) || %{}
  end

  defp account_data(diagnostics) do
    get_in(diagnostics, [:probes, :api, :data]) || %{}
  end

  defp teams_data(diagnostics) do
    get_in(diagnostics, [:probes, :teams, :data]) || %{}
  end

  defp states_data(diagnostics) do
    get_in(diagnostics, [:probes, :states, :data]) || %{}
  end

  defp project_team_names(project) do
    Enum.map_join(project.teams, ", ", & &1.name)
  end

  defp bootstrap_missing_states(diagnostics) do
    get_in(diagnostics, [:probes, :states, :data, :missing_states]) || []
  end

  defp bootstrap_available?(diagnostics) do
    bootstrap_missing_states(diagnostics) != [] and
      get_in(diagnostics, [:probes, :api, :status]) == :ok and
      get_in(diagnostics, [:probes, :project, :status]) == :ok and
      get_in(diagnostics, [:probes, :project, :data, :project, :teams]) not in [nil, []]
  end

  defp list_text([]), do: "none"
  defp list_text(values) when is_list(values), do: Enum.join(values, ", ")

  defp failed_text(failed) when is_list(failed) do
    Enum.map_join(failed, ", ", fn %{state: state, reason: reason} -> "#{state} (#{reason})" end)
  end

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_dt(_), do: "n/a"

  defp blockers_text([]), do: ""

  defp blockers_text(blockers) when is_list(blockers) do
    Enum.map_join(blockers, ", ", fn
      %{identifier: identifier, state: state} -> "#{identifier} (#{state})"
      %{"identifier" => identifier, "state" => state} -> "#{identifier} (#{state})"
      blocker -> inspect(blocker)
    end)
  end

  defp blockers_text(_blockers), do: ""
end
