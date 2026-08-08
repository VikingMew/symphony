defmodule SymphonyElixirWeb.AdminLive.ObservabilityComponents do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixirWeb.Admin.ObservabilityPresenter

  attr(:events, :list, required: true)

  @spec event_table(map()) :: Phoenix.LiveView.Rendered.t()
  def event_table(assigns) do
    ~H"""
    <%= if @events == [] do %>
      <p class="empty-state">No events recorded.</p>
    <% else %>
      <table class="data-table">
        <thead><tr><th>Time</th><th>Issue</th><th>Type</th><th>Payload</th></tr></thead>
        <tbody>
          <tr :for={event <- @events}>
            <td class="mono"><%= ObservabilityPresenter.fmt_dt(event.occurred_at) %></td>
            <td><%= event.issue_identifier || "n/a" %></td>
            <td><span class="status-badge status-info"><%= event.event_type %></span></td>
            <td><pre class="inline-code-panel"><%= ObservabilityPresenter.safe_event_payload(event.payload) %></pre></td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end
end
