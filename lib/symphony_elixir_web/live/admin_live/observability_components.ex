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

  attr(:issue, :map, required: true)

  @spec execution_routing(map()) :: Phoenix.LiveView.Rendered.t()
  def execution_routing(assigns) do
    assigns = assign(assigns, :routing, ObservabilityPresenter.issue_routing(assigns.issue))

    ~H"""
    <h2 class="section-title">Execution Routing</h2>
    <table class="data-table execution-routing-table">
      <tbody>
        <tr><th>Requirement</th><td><%= @routing.execution_requirement %></td></tr>
        <tr><th>Required capabilities</th><td><%= ObservabilityPresenter.capabilities_text(@routing.required_capabilities) %></td></tr>
        <tr><th>Routing status</th><td><%= @routing.routing_status %></td></tr>
        <tr><th>Reason</th><td><%= @routing.routing_reason || "n/a" %></td></tr>
        <tr><th>Eligible probes</th><td><%= @routing.eligible_probe_count || 0 %></td></tr>
        <tr><th>Selected probe</th><td><%= @routing.selected_probe_id || "n/a" %></td></tr>
        <tr><th>Waiting since</th><td class="mono"><%= @routing.routing_since_at || "n/a" %></td></tr>
        <tr><th>Wait</th><td><%= @routing.routing_wait_seconds || 0 %>s</td></tr>
        <tr><th>Threshold</th><td><span class={if(@routing.routing_alert, do: "status-badge status-danger", else: "status-badge")}><%= if(@routing.routing_alert, do: "alert", else: "below 30s") %></span></td></tr>
      </tbody>
    </table>
    """
  end
end
