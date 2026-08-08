defmodule SymphonyElixirWeb.AdminLive.IssueDetail do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.ObservabilityComponents, only: [event_table: 1]

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card">
      <h1 class="section-title">Issue Detail</h1>
      <%= if @issue_detail.issue do %>
        <pre class="code-panel"><%= inspect(@issue_detail.issue, pretty: true) %></pre>
      <% else %>
        <p class="empty-state">No persisted issue snapshot found for <span class="mono"><%= @route_params["identifier"] %></span>.</p>
      <% end %>

      <h2 class="section-title">Runs</h2>
      <%= if @issue_detail.runs_error do %>
        <p class="error-copy">Data unavailable: persisted runs for this issue could not be loaded.</p>
      <% else %>
      <%= if @issue_detail.runs == [] do %>
        <p class="empty-state">No persisted runs for this issue.</p>
      <% else %>
        <table class="data-table">
          <thead><tr><th>Run</th><th>Status</th><th>Started</th><th>Finished</th></tr></thead>
          <tbody>
            <tr :for={run <- @issue_detail.runs}>
              <td><a class="issue-link" href={"/runs/#{run.id}"}><%= run.id %></a></td>
              <td><%= run.status %></td>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(run.started_at) %></td>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(run.finished_at) %></td>
            </tr>
          </tbody>
        </table>
      <% end %>
      <% end %>

      <h2 class="section-title">Events</h2>
      <%= if @issue_detail.events_error do %>
        <p class="error-copy">Data unavailable: persisted events for this issue could not be loaded.</p>
      <% else %>
        <.event_table events={@issue_detail.events} />
      <% end %>
    </section>
    """
  end

  @spec assign_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_data(%{assigns: %{live_action: :issue_detail, route_params: %{"identifier" => identifier}}} = socket) do
    {runs, runs_error} = read_list(fn -> persistence().list_runs_for_issue(identifier, limit: 100) end)
    {events, events_error} = read_list(fn -> persistence().list_events(issue_identifier: identifier, limit: 100) end)

    assign(socket, :issue_detail, %{
      issue: persistence().get_issue_by_identifier(identifier),
      runs: runs,
      runs_error: runs_error,
      events: events,
      events_error: events_error
    })
  end

  def assign_data(socket) do
    assign_new(socket, :issue_detail, fn ->
      %{issue: nil, runs: [], runs_error: nil, events: [], events_error: nil}
    end)
  end

  defp read_list(fun) do
    case PersistenceProvider.read(fun) do
      records when is_list(records) -> {records, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp persistence, do: PersistenceProvider.module()
end
