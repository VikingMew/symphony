defmodule SymphonyElixirWeb.AdminLive.Settings.WorkflowDiscovery do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixir.Linear.StateFixes
  alias SymphonyElixir.Linear.WorkflowStateValidator
  alias SymphonyElixir.WorkflowForm
  alias SymphonyElixir.WorkflowValidator

  attr(:discovery, :any, required: true)
  attr(:draft, :map, required: true)

  @spec linear_workflow_discovery(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_workflow_discovery(assigns) do
    assigns =
      assign(assigns, :state_check, linear_workflow_state_check(assigns.draft, assigns.discovery))

    ~H"""
    <%= case @discovery do %>
      <% {:ok, discovery} -> %>
        <section class="workflow-form-section">
          <h3>Linear Workflow State Candidates</h3>
          <.linear_workflow_state_check_panel state_check={@state_check} />
          <div class="diagnostics-grid">
            <div>
              <h3 class="diagnostics-subtitle">Teams and States</h3>
              <%= if discovery.teams == [] do %>
                <p class="empty-state">No Linear teams returned.</p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr><th>Team</th><th>Key</th><th>States</th><th>Copy</th></tr>
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
        </section>
      <% _ -> %>
    <% end %>
    """
  end

  attr(:state_check, :any, required: true)

  @spec linear_workflow_state_check_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_workflow_state_check_panel(assigns) do
    ~H"""
    <%= case @state_check do %>
      <% {:ok, %{status: :ok}} -> %>
        <aside class="setup-guidance-card" role="status" aria-live="polite">
          <h3>Linear state check</h3>
          <p>Configured workflow states match the fetched Linear states.</p>
        </aside>
      <% {:ok, %{status: :error} = check} -> %>
        <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
          <h3>Linear state check</h3>
          <p>Settings are structurally valid, but these state names do not exist in the fetched Linear project. Rename them in Settings / Workflow or create the missing Linear statuses.</p>
          <ul>
            <li :for={item <- StateFixes.items(check)}>
              <div class="setup-guidance-item-heading">
                <span class="status-badge status-danger"><%= item.state %></span>
                <strong><%= item.references %></strong>
              </div>
              <span><%= item.action %></span>
            </li>
          </ul>
        </aside>
      <% _ -> %>
    <% end %>
    """
  end

  defp linear_workflow_state_check(draft, {:ok, discovery}) when is_map(draft) do
    with {:ok, raw} <- WorkflowForm.to_raw(draft),
         {:ok, %{settings: settings}} <- WorkflowValidator.validate_raw(raw, runtime?: false) do
      {:ok, WorkflowStateValidator.validate(settings, Map.get(discovery, :states, []))}
    else
      _ -> :unavailable
    end
  end

  defp linear_workflow_state_check(_draft, _discovery), do: :unavailable
end
