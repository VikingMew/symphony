defmodule SymphonyElixirWeb.AdminLive.Settings.Projects do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixirWeb.Admin.{ProjectSettings, SettingsCheck}
  alias SymphonyElixirWeb.AdminLive.{State, WorkflowState}

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card settings-content-card">
      <h2 class="section-title">Projects</h2>
      <p class="metric-label">Each project owns its Linear project slug, repository URL, and default branch. Workflow and agent policy remain shared.</p>
      <%= if @project_configuration_items != [] do %>
        <aside class="setup-guidance-card" role="status" aria-live="polite">
          <h3>Project configuration checklist</h3>
          <ul>
            <li :for={item <- @project_configuration_items}>
              <div class="setup-guidance-item-heading">
                <span class="status-badge status-info"><%= item.scope %></span>
                <strong><%= item.title %></strong>
              </div>
              <span><%= item.detail %></span>
            </li>
          </ul>
        </aside>
      <% end %>

      <.linear_project_discovery discovery={@linear_discovery} />

      <%= if @workflow_save_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @workflow_save_notice.title %></strong>
          <span><%= @workflow_save_notice.message %></span>
        </aside>
      <% end %>

      <div class="workflow-profile-grid">
        <article :for={project <- @projects} class="workflow-profile-panel">
          <header class="workflow-profile-header">
            <div>
              <h4><%= project.name %></h4>
              <p class="metric-label mono"><%= project.slug %></p>
            </div>
            <div class="button-row">
              <span class={if project.enabled, do: "status-badge status-info", else: "status-badge"}><%= if project.enabled, do: "enabled", else: "disabled" %></span>
              <button
                type="button"
                class="subtle-button"
                phx-click="remove_project"
                phx-value-project_id={project.id}
                data-confirm={"Remove #{project.name}? Its workflow will also be removed."}
              >
                Remove
              </button>
            </div>
          </header>

          <form class="workflow-form settings-editor-form project-edit-form" data-project-id={project.id} phx-submit="save_project_settings">
            <input type="hidden" name="project[id]" value={project.id} />
            <div class="workflow-profile-field-grid">
              <label class="settings-field"><span class="metric-label">Name</span><input name="project[name]" value={project.name} /></label>
              <label class="settings-field"><span class="metric-label">Internal slug</span><input name="project[slug]" value={project.slug} /></label>
              <label class={project_field_class(@project_configuration_items, "Linear project slug")}><span class={project_field_title_class(@project_configuration_items, "Linear project slug")}>Linear project slug</span><input name="project[linear_project_slug]" value={ProjectSettings.value(project, :linear_project_slug)} /></label>
              <label class={project_field_class(@project_configuration_items, "Repository URL")}><span class={project_field_title_class(@project_configuration_items, "Repository URL")}>Repository URL</span><input name="project[repository_url]" value={ProjectSettings.value(project, :repository_url)} /></label>
              <label class="settings-field"><span class="metric-label">Default branch</span><input name="project[default_branch]" value={ProjectSettings.value(project, :default_branch) || "main"} /></label>
              <label class="settings-field"><span class="metric-label">Checkout depth</span><input type="number" min="1" name="project[checkout_depth]" value={ProjectSettings.value(project, :checkout_depth) || 1} /></label>
              <label class="settings-field">
                <span class="metric-label">Source strategy</span>
                <select name="project[source_strategy]">
                  <option value="clone" selected={ProjectSettings.value(project, :source_strategy) in [nil, "clone"]}>clone</option>
                  <option value="worktree" selected={ProjectSettings.value(project, :source_strategy) == "worktree"}>worktree</option>
                </select>
              </label>
              <div class="workflow-checkbox-row">
                <input type="hidden" name="project[worktree_fetch]" value="false" />
                <label><input type="checkbox" name="project[worktree_fetch]" value="true" checked={ProjectSettings.value(project, :worktree_fetch) != false} /> Fetch before worktree</label>
                <input type="hidden" name="project[worktree_cleanup]" value="false" />
                <label><input type="checkbox" name="project[worktree_cleanup]" value="true" checked={ProjectSettings.value(project, :worktree_cleanup) != false} /> Clean stale worktree</label>
              </div>
              <label class="settings-field"><span class="metric-label">Description</span><input name="project[description]" value={ProjectSettings.value(project, :description)} /></label>
              <div class="workflow-checkbox-row">
                <input type="hidden" name="project[enabled]" value="false" />
                <label><input type="checkbox" name="project[enabled]" value="true" checked={project.enabled} /> Enabled</label>
              </div>
            </div>
            <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save project</button>
          </form>
        </article>
      </div>

      <section class="workflow-form-section">
        <h3>Add Project</h3>
        <form class="workflow-form settings-editor-form project-create-form" phx-submit="save_project_settings">
          <div class="workflow-profile-field-grid">
            <label class="settings-field"><span class="metric-label">Name</span><input name="project[name]" /></label>
            <label class="settings-field"><span class="metric-label">Internal slug</span><input name="project[slug]" /></label>
            <label class="settings-field"><span class="metric-label">Linear project slug</span><input name="project[linear_project_slug]" /></label>
            <label class="settings-field"><span class="metric-label">Repository URL</span><input name="project[repository_url]" /></label>
            <label class="settings-field"><span class="metric-label">Default branch</span><input name="project[default_branch]" value="main" /></label>
            <label class="settings-field"><span class="metric-label">Checkout depth</span><input type="number" min="1" name="project[checkout_depth]" value="1" /></label>
            <label class="settings-field">
              <span class="metric-label">Source strategy</span>
              <select name="project[source_strategy]">
                <option value="clone" selected>clone</option>
                <option value="worktree">worktree</option>
              </select>
            </label>
            <div class="workflow-checkbox-row">
              <input type="hidden" name="project[worktree_fetch]" value="false" />
              <label><input type="checkbox" name="project[worktree_fetch]" value="true" checked /> Fetch before worktree</label>
              <input type="hidden" name="project[worktree_cleanup]" value="false" />
              <label><input type="checkbox" name="project[worktree_cleanup]" value="true" checked /> Clean stale worktree</label>
            </div>
            <label class="settings-field"><span class="metric-label">Description</span><input name="project[description]" /></label>
            <div class="workflow-checkbox-row">
              <input type="hidden" name="project[enabled]" value="false" />
              <label><input type="checkbox" name="project[enabled]" value="true" checked /> Enabled</label>
            </div>
          </div>
          <button class="subtle-button" type="submit" phx-disable-with="Saving...">Add project</button>
        </form>
      </section>
    </section>
    """
  end

  @spec save(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def save(params, socket) do
    id = SymphonyElixir.Text.blank_as_nil(Map.get(params, "id"))
    attrs = ProjectSettings.attrs(params)

    result =
      case id do
        nil -> persistence().create_project(attrs) |> PersistenceProvider.publish_runtime_mutation()
        id -> maybe_update_project(id, attrs, socket)
      end

    socket =
      case result do
        :unchanged ->
          socket
          |> put_flash(:info, "Project settings already up to date.")
          |> WorkflowState.assign_save_notice(:info, "Project settings already up to date", "No changes to save.")

        {:ok, project} ->
          socket
          |> put_flash(:info, "Project settings saved.")
          |> WorkflowState.assign_save_notice(:success, "Project settings saved", "#{project.name} is available in Settings.")
          |> State.refresh()

        {:error, reason} ->
          message = changeset_or_reason(reason)

          socket
          |> put_flash(:error, "Project settings rejected: #{message}")
          |> WorkflowState.assign_save_notice(:error, "Project settings failed", message)
      end

    {:noreply, socket}
  end

  @spec remove(String.t(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def remove(id, socket) do
    socket =
      case persistence().delete_project(id) |> PersistenceProvider.publish_runtime_mutation() do
        {:ok, project} ->
          socket
          |> put_flash(:info, "Project #{project.name} removed.")
          |> WorkflowState.assign_save_notice(
            :success,
            "Project removed",
            "Project #{project.name} removed."
          )
          |> State.refresh()

        {:error, reason} ->
          message = changeset_or_reason(reason)

          socket
          |> put_flash(:error, "Project removal failed: #{message}")
          |> WorkflowState.assign_save_notice(:error, "Project removal failed", message)
      end

    {:noreply, socket}
  end

  attr(:discovery, :any, required: true)

  @spec linear_project_discovery(map()) :: Phoenix.LiveView.Rendered.t()
  def linear_project_discovery(assigns) do
    ~H"""
    <%= case @discovery do %>
      <% {:ok, discovery} -> %>
        <section class="workflow-form-section">
          <h3>Linear Project Candidates</h3>
          <%= if discovery.projects == [] do %>
            <p class="empty-state">No Linear projects returned.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr><th>Name</th><th>Slug</th><th>Teams</th><th>URL</th><th>Copy</th></tr>
                </thead>
                <tbody>
                  <tr :for={project <- discovery.projects}>
                    <td><%= project.name %></td>
                    <td class="mono"><%= project.slug %></td>
                    <td><%= ProjectSettings.team_names(project) %></td>
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
        </section>
      <% _ -> %>
    <% end %>
    """
  end

  defp maybe_update_project(id, attrs, socket) do
    case Enum.find(socket.assigns.projects, &(ProjectSettings.value(&1, :id) == id)) do
      nil ->
        persistence().update_project(id, attrs) |> PersistenceProvider.publish_runtime_mutation()

      project ->
        if ProjectSettings.changed?(project, attrs),
          do: persistence().update_project(id, attrs) |> PersistenceProvider.publish_runtime_mutation(),
          else: :unchanged
    end
  end

  defp changeset_or_reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end

  defp changeset_or_reason(reason), do: inspect(reason)
  defp project_field_class(items, title), do: SettingsCheck.project_field_class(items, title)
  defp project_field_title_class(items, title), do: SettingsCheck.project_field_title_class(items, title)
  defp persistence, do: PersistenceProvider.module()
end
