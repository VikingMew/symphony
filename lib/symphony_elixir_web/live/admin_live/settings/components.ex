defmodule SymphonyElixirWeb.AdminLive.Settings.Components do
  @moduledoc false

  use Phoenix.Component

  alias SymphonyElixirWeb.Admin.SettingsCheck

  @spec tab(atom()) :: :agents | :import | :projects | :runtime | :workflow
  def tab(:settings), do: :projects
  def tab(:settings_projects), do: :projects
  def tab(:settings_workflow), do: :workflow
  def tab(:settings_agents), do: :agents
  def tab(:settings_runtime), do: :runtime
  def tab(:settings_import), do: :import

  @spec label(atom()) :: String.t()
  def label(:projects), do: "Projects"
  def label(:workflow), do: "Workflow"
  def label(:agents), do: "Agents"
  def label(:runtime), do: "Runtime"
  def label(:import), do: "Import"
  def label(tab), do: to_string(tab)

  @spec path(atom()) :: String.t()
  def path(:projects), do: "/settings/projects"
  def path(:workflow), do: "/settings/workflow"
  def path(:agents), do: "/settings/agents"
  def path(:runtime), do: "/settings/runtime"
  def path(:import), do: "/settings/import"
  def path(_tab), do: "/settings"

  attr(:active, :atom, required: true)
  attr(:project, :any, default: nil)

  @spec settings_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, [
        {:projects, "Projects", "/settings/projects"},
        {:workflow, "Workflow", "/settings/workflow"},
        {:agents, "Agents", "/settings/agents"},
        {:runtime, "Runtime", "/settings/runtime"},
        {:import, "Import", "/settings/import"}
      ])

    ~H"""
    <nav class="settings-tabs" aria-label="Settings sections">
      <.link
        :for={{key, label, path} <- @tabs}
        class="settings-tab-link"
        patch={settings_tab_link(path, @project)}
        aria-current={if key == @active, do: "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  attr(:targets, :list, required: true)
  attr(:tab, :atom, required: true)
  attr(:field, :atom, required: true)
  attr(:scope, :any, default: nil)

  @spec settings_check_messages(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_check_messages(assigns) do
    assigns = assign(assigns, :messages, SettingsCheck.messages(assigns.targets, assigns.tab, assigns.field, assigns.scope))

    ~H"""
    <p :for={message <- @messages} class="settings-check-message"><%= message %></p>
    """
  end

  attr(:targets, :list, required: true)
  attr(:current_tab, :atom, required: true)

  @spec settings_check_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_check_summary(assigns) do
    ~H"""
    <aside :if={@targets != []} class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
      <h3>Configuration check targets</h3>
      <ul>
        <li :for={target <- @targets}>
          <div class="setup-guidance-item-heading">
            <span class="status-badge status-danger"><%= label(target.tab) %></span>
            <strong><%= target.title %></strong>
          </div>
          <span><%= target.message %></span>
          <a :if={target.tab != @current_tab} class="issue-link" href={path(target.tab)}>Open <%= label(target.tab) %></a>
        </li>
      </ul>
    </aside>
    """
  end

  defp settings_tab_link(path, nil), do: path
  defp settings_tab_link(path, project_id), do: "#{path}?project=#{project_id}"
end
