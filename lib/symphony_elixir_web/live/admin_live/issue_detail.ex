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

      <h2 class="section-title">Events</h2>
      <.event_table events={@issue_detail.events} />
    </section>
    """
  end

  @spec assign_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_data(%{assigns: %{live_action: :issue_detail, route_params: %{"identifier" => identifier}}} = socket) do
    assign(socket, :issue_detail, %{
      issue: persistence().get_issue_by_identifier(identifier),
      runs: persistence().list_runs_for_issue(identifier, limit: 100),
      events: persistence().list_events(issue_identifier: identifier, limit: 100)
    })
  end

  def assign_data(socket) do
    assign_new(socket, :issue_detail, fn -> %{issue: nil, runs: [], events: []} end)
  end

  defp persistence, do: PersistenceProvider.module()
end
