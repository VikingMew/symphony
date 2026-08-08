defmodule SymphonyElixirWeb.AdminLive.RunDetail do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.ObservabilityComponents, only: [event_table: 1]

  alias SymphonyElixir.{PersistenceProvider, RunHistory}
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card">
      <h1 class="section-title">Run Detail</h1>
      <%= if @run_detail.run do %>
        <table class="data-table">
          <tbody>
            <tr><th>Run ID</th><td class="mono"><%= @run_detail.run.id %></td></tr>
            <tr><th>Kind</th><td><%= Map.get(@run_detail.run, :kind) || "issue" %></td></tr>
            <tr><th>Label</th><td><%= run_label(@run_detail.run) %></td></tr>
            <tr :if={Map.get(@run_detail.run, :issue_identifier)}><th>Issue</th><td><a class="issue-link" href={"/issues/#{@run_detail.run.issue_identifier}"}><%= @run_detail.run.issue_identifier %></a></td></tr>
            <tr><th>Status</th><td><span class={ObservabilityPresenter.status_class(@run_detail.run.status)}><%= @run_detail.run.status %></span></td></tr>
            <tr><th>Attempt</th><td><%= @run_detail.run.attempt %></td></tr>
            <tr><th>Worker</th><td><%= Map.get(@run_detail.run, :worker_host) || "local" %></td></tr>
            <tr><th>Workspace</th><td class="mono"><%= Map.get(@run_detail.run, :workspace_path) || "n/a" %></td></tr>
            <tr><th>Started</th><td class="mono"><%= ObservabilityPresenter.fmt_dt(@run_detail.run.started_at) %></td></tr>
            <tr><th>Finished</th><td class="mono"><%= ObservabilityPresenter.fmt_dt(@run_detail.run.finished_at) %></td></tr>
            <tr><th>Duration</th><td><%= ObservabilityPresenter.fmt_duration(@run_detail.run.started_at, @run_detail.run.finished_at) %></td></tr>
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
          <pre class="code-panel"><%= ObservabilityPresenter.workflow_version_summary(@run_detail.workflow_version) %></pre>
        <% else %>
          <p class="empty-state">No workflow version is attached to this run.</p>
        <% end %>

        <h2 class="section-title">Session History</h2>
        <%= if @run_detail.session_history == [] do %>
          <p class="empty-state">No session history recorded for this run.</p>
        <% else %>
          <table class="data-table">
            <thead><tr><th>Time</th><th>Source</th><th>Event</th><th>Detail</th></tr></thead>
            <tbody>
              <tr :for={event <- @run_detail.session_history}>
                <td class="mono"><%= ObservabilityPresenter.fmt_dt(event.at) %></td>
                <td><span class={ObservabilityPresenter.status_class(to_string(event.severity || :info))}><%= event.source || "n/a" %></span></td>
                <td><%= event.label %></td>
                <td>
                  <div><%= event.detail || "n/a" %></div>
                  <details :if={event.metadata != %{}} class="event-metadata">
                    <summary>Payload</summary>
                    <pre class="inline-code-panel"><%= ObservabilityPresenter.safe_event_payload(event.metadata) %></pre>
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
    """
  end

  @spec assign_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_data(%{assigns: %{live_action: :run_detail, route_params: %{"id" => id}}} = socket) do
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
      session_history: session_history,
      summary: RunHistory.summarize(run, session_history),
      events: if(run, do: persistence().list_events(run_id: run.id, limit: 100), else: [])
    })
  end

  def assign_data(socket) do
    assign_new(socket, :run_detail, fn ->
      %{
        run: nil,
        workflow_version: nil,
        session_history: [],
        summary: RunHistory.summarize(nil, []),
        events: []
      }
    end)
  end

  defp run_label(run) do
    Map.get(run, :label) || Map.get(run, :issue_identifier) || Map.get(run, :id) || "n/a"
  end

  defp list_summary([]), do: "n/a"
  defp list_summary(values) when is_list(values), do: Enum.join(values, " | ")

  defp persistence, do: PersistenceProvider.module()
end
