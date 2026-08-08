defmodule SymphonyElixirWeb.AdminLive.Settings.Runtime do
  @moduledoc false

  use Phoenix.Component

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card">
      <h2 class="section-title">Runtime</h2>
      <p class="metric-label">Execution mode: <span class="status-badge status-info"><%= @execution_mode %></span></p>
      <%= if @runtime_configuration_items != [] do %>
        <aside class="setup-guidance-card" role="status" aria-live="polite">
          <h3>Runtime configuration checklist</h3>
          <ul>
            <li :for={item <- @runtime_configuration_items}>
              <div class="setup-guidance-item-heading">
                <span class="status-badge status-info"><%= item.scope %></span>
                <strong><%= item.title %></strong>
              </div>
              <span><%= item.detail %></span>
            </li>
          </ul>
        </aside>
      <% end %>
    </section>
    """
  end
end
