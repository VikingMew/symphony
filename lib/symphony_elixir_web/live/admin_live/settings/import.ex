defmodule SymphonyElixirWeb.AdminLive.Settings.Import do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.LiveView,
    only: [consume_uploaded_entries: 3, put_flash: 3, uploaded_entries: 2]

  alias SymphonyElixir.{PersistenceProvider, WorkflowForm, WorkflowSettingsPackage}
  alias SymphonyElixirWeb.Admin.ProjectSettings
  alias SymphonyElixirWeb.AdminLive.State

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card settings-content-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">Import Settings Package</h2>
          <p class="section-copy">Paste or upload workflow.yml or profiles.yml. Review Instance and Project changes by durable scope, then confirm the import. Project changes require an explicitly selected target.</p>
        </div>
        <span class="status-badge status-info">staged review</span>
      </div>

      <%= if @workflow_import_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_import_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @workflow_import_notice.title %></strong>
          <span><%= @workflow_import_notice.message %></span>
        </aside>
      <% end %>

      <form class="workflow-form settings-editor-form" phx-submit="stage_settings_import" phx-change="validate_settings_import_upload">
        <section class="workflow-form-section">
          <h3>Source</h3>
          <label>
            <span class="metric-label">Paste YAML</span>
            <textarea class="workflow-textbox workflow-textbox-medium" name="import[yaml]" rows="8" placeholder="Paste workflow.yml or profiles.yml"><%= @settings_import_yaml %></textarea>
          </label>
          <label>
            <span class="metric-label">Upload file</span>
            <.live_file_input upload={@uploads.settings_package} />
          </label>
          <button class="subtle-button" type="submit" phx-disable-with="Reviewing...">Review import</button>
        </section>
      </form>

      <%= if @settings_import_stage do %>
        <section class="workflow-form-section settings-import-review">
          <div class="workflow-form-header settings-action-row">
            <div>
              <h3>Review staged import</h3>
              <p class="workflow-help-copy">
                Detected <span class="mono"><%= @settings_import_stage.label %></span>.
                Affects <%= Enum.join(@settings_import_stage.affected_areas, ", ") %>.
              </p>
            </div>
            <span class="status-badge status-info"><%= @settings_import_stage.source %></span>
          </div>
          <div class="workflow-summary-grid">
            <p><span class="metric-label">Package type</span><strong><%= @settings_import_stage.detected_type %></strong></p>
            <p><span class="metric-label">Changes</span><strong><%= length(@settings_import_stage.diff) %></strong></p>
            <p><span class="metric-label">Durable scopes</span><strong><%= Enum.join(@settings_import_stage.affected_scopes, " + ") %></strong></p>
          </div>
          <%= if @settings_import_stage.diff == [] do %>
            <p class="empty-state">No draft changes detected.</p>
          <% else %>
            <section :for={scope <- ["Instance", "Project"]} :if={scope in @settings_import_stage.affected_scopes} class="settings-import-scope-group">
              <h4><%= scope_heading(scope, @settings_import_stage.project_target) %></h4>
              <div class="table-wrap">
                <table class="data-table settings-import-diff-table">
                  <thead><tr><th>Area</th><th>Field</th><th>Before</th><th>After</th></tr></thead>
                  <tbody>
                    <tr :for={change <- Enum.filter(@settings_import_stage.diff, &(&1.scope == scope))}>
                      <td><span class="status-badge status-info"><%= change.area %></span></td>
                      <td class="mono"><%= change.path %></td>
                      <td><pre class="inline-code-panel"><%= change.before %></pre></td>
                      <td><pre class="inline-code-panel"><%= change.after %></pre></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          <% end %>
          <details>
            <summary>Raw source preview</summary>
            <pre class="code-panel"><%= @settings_import_stage.preview %></pre>
          </details>
          <div class="button-row">
            <button type="button" class="subtle-button" phx-click="confirm_settings_import" phx-disable-with="Applying...">Confirm import</button>
            <button type="button" class="subtle-button" phx-click="cancel_settings_import">Cancel</button>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  @spec stage(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def stage(params, socket) do
    pasted = Map.get(params, "yaml", "")
    yaml = import_upload_content(socket) || pasted
    source = import_source(socket, pasted)
    import_form = socket.assigns.settings_import_form

    socket =
      with :ok <- WorkflowSettingsPackage.require_import_content(yaml),
           {:ok, stage} <- WorkflowSettingsPackage.stage_import(yaml, import_form, source: source) do
        stage = Map.put(stage, :project_target, socket.assigns.explicit_project)

        socket
        |> put_flash(:info, "#{stage.label} staged for review.")
        |> assign_import_notice(
          :success,
          "#{stage.label} staged",
          "Review the Instance and Project changes, then confirm the durable write."
        )
        |> assign(:settings_import_yaml, yaml)
        |> assign(:settings_import_stage, stage)
      else
        {:error, reason} ->
          message = WorkflowSettingsPackage.import_error_message(reason)

          socket
          |> put_flash(:error, "Settings package import failed: #{message}")
          |> assign_import_notice(:error, "Package import failed", message)
          |> assign(:settings_import_stage, nil)
      end

    {:noreply, socket}
  end

  @spec confirm(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def confirm(socket) do
    case socket.assigns.settings_import_stage do
      %{draft: draft, label: label} = stage ->
        persist_stage(socket, stage, draft, label)

      _stage ->
        {:noreply, assign_import_notice(socket, :error, "No staged import", "Paste or upload a settings package before confirming.")}
    end
  end

  @spec cancel(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def cancel(socket) do
    {:noreply,
     socket
     |> assign(:settings_import_stage, nil)
     |> assign(:settings_import_yaml, "")
     |> assign_import_notice(:info, "Import cancelled", "No durable settings were changed.")}
  end

  attr(:notice, :any, default: nil)

  @spec settings_import_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_import_panel(assigns) do
    ~H"""
    <section class="workflow-form-section settings-import-panel">
      <div class="workflow-form-header settings-action-row">
        <div>
          <h3>Import Settings Package</h3>
          <p class="workflow-help-copy">Import workflow.yml or profiles.yml into this structured draft. Symphony detects the file type from YAML fields. Import does not save or activate until you press Save.</p>
        </div>
        <span class="status-badge status-info">draft only</span>
      </div>

      <%= if @notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@notice.level}"]} role="status" aria-live="polite">
          <strong><%= @notice.title %></strong>
          <span><%= @notice.message %></span>
        </aside>
      <% end %>

      <form class="workflow-form settings-import-form" phx-submit="import_settings_package">
        <label>
          <span class="metric-label">YAML</span>
          <textarea class="workflow-textbox workflow-textbox-medium" name="import[yaml]" rows="7" placeholder="Paste workflow.yml or profiles.yml"></textarea>
        </label>
        <button class="subtle-button" type="submit" phx-disable-with="Importing...">Import</button>
      </form>
    </section>
    """
  end

  defp import_upload_content(socket) do
    case uploaded_entries(socket, :settings_package) do
      {[_entry | _], _in_progress} ->
        socket
        |> consume_uploaded_entries(:settings_package, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)
        |> List.first()

      _entries ->
        nil
    end
  end

  defp import_source(socket, pasted) do
    case uploaded_entries(socket, :settings_package) do
      {[_entry | _], _in_progress} -> :upload
      _entries -> if SymphonyElixir.Text.blankish?(pasted), do: :unknown, else: :paste
    end
  end

  defp assign_import_notice(socket, level, title, message) do
    assign(socket, :workflow_import_notice, %{level: level, title: title, message: message})
  end

  defp persist_stage(socket, stage, draft, label) do
    cond do
      "Project" in stage.affected_scopes and is_nil(stage.project_target) ->
        project_target_required(socket)

      "Project" in stage.affected_scopes ->
        persist_combined_stage(socket, stage.project_target, draft, label)

      true ->
        persist_instance_stage(socket, draft, label)
    end
  end

  defp project_target_required(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Settings package import rejected: project_target_required")
     |> assign_import_notice(
       :error,
       "Project target required",
       "project_target_required: select a project explicitly before confirming Project scope changes."
     )}
  end

  defp persist_combined_stage(socket, project, draft, label) do
    with {:ok, raw} <- WorkflowForm.to_raw(draft),
         {:ok, result} <- import_package(project, raw) do
      project_name = ProjectSettings.value(project, :name)

      {:noreply,
       socket
       |> put_flash(:info, "#{label} imported to Instance and Project #{project_name}.")
       |> assign_import_notice(
         :success,
         "Instance and Project settings imported",
         "Instance singleton and Project #{project_name} were written atomically: #{import_result(result)}"
       )
       |> assign(:settings_import_stage, nil)
       |> State.refresh()}
    else
      {:error, reason} -> import_error(socket, reason)
    end
  end

  defp persist_instance_stage(socket, draft, label) do
    with {:ok, instance} <- WorkflowForm.to_instance_scope(draft),
         {:ok, _stored} <- put_instance(instance) do
      {:noreply,
       socket
       |> put_flash(:info, "#{label} imported to the Instance singleton.")
       |> assign_import_notice(
         :success,
         "Instance settings imported",
         "Instance singleton updated for all enabled projects."
       )
       |> assign(:settings_import_stage, nil)
       |> State.refresh()}
    else
      {:error, reason} -> import_error(socket, reason)
    end
  end

  defp import_package(project, raw) do
    project
    |> persistence().import_package(raw, "web_settings_import")
    |> PersistenceProvider.publish_runtime_mutation()
  end

  defp put_instance(%{config: config, prompt_body: prompt_body}) do
    config
    |> persistence().put_instance_workflow(prompt_body)
    |> PersistenceProvider.publish_runtime_mutation()
  end

  defp import_error(socket, reason) do
    message = WorkflowSettingsPackage.import_error_message(reason)

    {:noreply,
     socket
     |> put_flash(:error, "Settings package import failed: #{message}")
     |> assign_import_notice(:error, "Package import failed", message)}
  end

  defp import_result(%{instance_workflow: _instance, project_workflow: _project}),
    do: "both durable scopes saved"

  defp scope_heading("Instance", _project), do: "Instance"
  defp scope_heading("Project", nil), do: "Project — no target selected"

  defp scope_heading("Project", project) do
    "Project — #{ProjectSettings.value(project, :name)} (#{ProjectSettings.value(project, :slug)})"
  end

  defp persistence, do: PersistenceProvider.module()
end
