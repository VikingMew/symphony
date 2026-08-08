defmodule SymphonyElixirWeb.AdminLive.Settings.Import do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.LiveView,
    only: [consume_uploaded_entries: 3, put_flash: 3, push_patch: 2, uploaded_entries: 2]

  alias SymphonyElixir.WorkflowSettingsPackage
  alias SymphonyElixirWeb.AdminLive.Settings.Components
  alias SymphonyElixirWeb.AdminLive.WorkflowState

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card settings-content-card">
      <div class="section-header">
        <div>
          <h2 class="section-title">Import Settings Package</h2>
          <p class="section-copy">Paste or upload workflow.yml or profiles.yml. Import is staged for review before it changes the editable draft, and runtime configuration is unchanged until the normal Save flow.</p>
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
            <p><span class="metric-label">Next page</span><strong><%= Components.label(@settings_import_stage.owning_tab) %></strong></p>
          </div>
          <%= if @settings_import_stage.diff == [] do %>
            <p class="empty-state">No draft changes detected.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table settings-import-diff-table">
                <thead><tr><th>Area</th><th>Field</th><th>Before</th><th>After</th></tr></thead>
                <tbody>
                  <tr :for={change <- @settings_import_stage.diff}>
                    <td><span class="status-badge status-info"><%= change.area %></span></td>
                    <td class="mono"><%= change.path %></td>
                    <td><pre class="inline-code-panel"><%= change.before %></pre></td>
                    <td><pre class="inline-code-panel"><%= change.after %></pre></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
          <details>
            <summary>Raw source preview</summary>
            <pre class="code-panel"><%= @settings_import_stage.preview %></pre>
          </details>
          <div class="button-row">
            <button type="button" class="subtle-button" phx-click="confirm_settings_import" phx-disable-with="Applying...">Confirm import to draft</button>
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

    socket =
      with :ok <- WorkflowSettingsPackage.require_import_content(yaml),
           {:ok, stage} <- WorkflowSettingsPackage.stage_import(yaml, socket.assigns.workflow_form, source: source) do
        socket
        |> put_flash(:info, "#{stage.label} staged for review.")
        |> assign_import_notice(
          :success,
          "#{stage.label} staged",
          "Review the detected changes, then confirm to update the editable Settings draft."
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
      %{draft: draft, label: label, owning_tab: owning_tab} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{label} applied to the editable draft. Save #{WorkflowState.section_label(owning_tab)} to activate it.")
         |> assign_import_notice(:success, "#{label} applied to draft", "Runtime configuration is unchanged until you save.")
         |> assign(:workflow_save_notice, nil)
         |> assign(:workflow_validation_visible?, true)
         |> assign(:workflow_form, draft)
         |> assign(:workflow_form_dirty?, true)
         |> assign(:settings_import_stage, nil)
         |> WorkflowState.assign_validation(draft)
         |> push_patch(to: Components.path(owning_tab))}

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
     |> assign_import_notice(:info, "Import cancelled", "The editable Settings draft was not changed.")}
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
end
