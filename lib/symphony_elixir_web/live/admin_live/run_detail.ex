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
            <tr :if={Map.get(@run_detail.run, :execution_mode) != "worker"}><th>Workspace</th><td class="mono"><%= Map.get(@run_detail.run, :workspace_path) || "n/a" %></td></tr>
            <tr><th>Started</th><td class="mono"><%= ObservabilityPresenter.fmt_dt(@run_detail.run.started_at) %></td></tr>
            <tr><th>Finished</th><td class="mono"><%= ObservabilityPresenter.fmt_dt(@run_detail.run.finished_at) %></td></tr>
            <tr><th>Duration</th><td><%= ObservabilityPresenter.fmt_duration(@run_detail.run.started_at, @run_detail.run.finished_at) %></td></tr>
            <tr><th>Failure</th><td><%= Map.get(@run_detail.run, :failure_reason) || "n/a" %></td></tr>
          </tbody>
        </table>

        <%= if summary = Map.get(@run_detail.run, :execution_summary) do %>
          <h2 class="section-title">Worker Execution Evidence</h2>
          <table class="data-table">
            <tbody>
              <tr><th>Phase / outcome</th><td><%= summary["phase"] %> / <%= summary["outcome"] %></td></tr>
              <tr><th>Validation</th><td><%= summary["validation_status"] %></td></tr>
              <tr><th>Occurred</th><td class="mono"><%= summary["occurred_at"] %></td></tr>
              <tr><th>Duration</th><td><%= duration_ms(summary["duration_ms"]) %></td></tr>
              <tr><th>Source revision</th><td class="mono"><%= summary["source_revision"] %></td></tr>
              <tr><th>Runtime</th><td class="mono"><%= runtime_identity(summary["runtime"]) %></td></tr>
              <tr><th>Handoff</th><td class="mono"><%= handoff_refs(summary["handoff"]) %></td></tr>
            </tbody>
          </table>
          <table :if={summary["gates"] != []} class="data-table">
            <thead><tr><th>Gate</th><th>Status</th><th>Exit</th><th>Duration</th><th>Timeout</th><th>Detail</th></tr></thead>
            <tbody>
              <tr :for={gate <- summary["gates"]}>
                <td><%= gate["name"] %></td><td><%= gate["status"] %></td><td><%= gate["exit_code"] || "n/a" %></td>
                <td><%= duration_ms(gate["duration_ms"]) %></td><td><%= duration_ms(gate["timeout_ms"]) %></td><td><%= gate["failure_detail"] || "n/a" %></td>
              </tr>
            </tbody>
          </table>
        <% end %>

        <%= if @run_detail.history_error do %>
          <h2 class="section-title">Agent Summary</h2>
          <p class="error-copy">Data unavailable: persisted session history could not be loaded.</p>
        <% else %>
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
        <% end %>

        <h2 class="section-title">Session History</h2>
        <%= if @run_detail.history_error do %>
          <p class="error-copy">Data unavailable: persisted session history could not be loaded.</p>
        <% else %>
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
        <% end %>

        <h2 class="section-title">Raw Events</h2>
        <%= if @run_detail.events_error do %>
          <p class="error-copy">Data unavailable: persisted events could not be loaded.</p>
        <% else %>
          <.event_table events={@run_detail.events} />
        <% end %>
      <% else %>
        <p class="empty-state">Run not found.</p>
      <% end %>
    </section>
    """
  end

  @spec assign_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_data(%{assigns: %{live_action: :run_detail, route_params: %{"id" => id}}} = socket) do
    run = persistence().get_run(id)

    {session_history, history_error} =
      if run do
        read_list(fn -> RunHistory.list_run_session_events(persistence(), run.id, limit: 100) end)
      else
        {[], nil}
      end

    {events, events_error} =
      if run do
        read_list(fn -> persistence().list_events(run_id: run.id, limit: 100) end)
      else
        {[], nil}
      end

    assign(socket, :run_detail, %{
      run: run,
      session_history: session_history,
      history_error: history_error,
      summary: RunHistory.summarize(run, session_history),
      events: events,
      events_error: events_error
    })
  end

  def assign_data(socket) do
    assign_new(socket, :run_detail, fn ->
      %{
        run: nil,
        session_history: [],
        history_error: nil,
        summary: RunHistory.summarize(nil, []),
        events: [],
        events_error: nil
      }
    end)
  end

  defp read_list(fun) do
    case PersistenceProvider.read(fun) do
      records when is_list(records) -> {records, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp run_label(run) do
    Map.get(run, :label) || Map.get(run, :issue_identifier) || Map.get(run, :id) || "n/a"
  end

  defp list_summary([]), do: "n/a"
  defp list_summary(values) when is_list(values), do: Enum.join(values, " | ")

  defp duration_ms(value) when is_integer(value), do: "#{value} ms"
  defp duration_ms(_value), do: "n/a"
  defp runtime_identity(nil), do: "n/a"
  defp runtime_identity(runtime) do
    [runtime["image_digest"] || runtime["image_tag"], runtime["worker_source_revision"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end
  defp handoff_refs(nil), do: "n/a"

  defp handoff_refs(handoff) do
    [
      handoff["branch"],
      handoff["commit"],
      handoff["pr_identifier"],
      handoff["pr_url"],
      handoff["linear_issue"],
      handoff["linear_state"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
    |> case do
      "" -> "n/a"
      refs -> refs
    end
  end

  defp persistence, do: PersistenceProvider.module()
end
