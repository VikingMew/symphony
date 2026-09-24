defmodule SymphonyElixirWeb.AdminLive.Settings.Runtime do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.Settings.Components,
    only: [settings_check_messages: 1, settings_check_summary: 1]

  alias SymphonyElixir.Codex.ModelCatalog
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixirWeb.Admin.ProjectSettings
  alias SymphonyElixirWeb.Admin.SettingsCheck

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    workflow_form = Map.get(assigns, :workflow_form, %{})
    selected_model = Map.get(workflow_form, "codex_model", "")
    legacy_drift = SettingsCheck.legacy_instance_drift(Map.get(assigns, :legacy_instance_workflow_status))
    selected_source = selected_drift_source(legacy_drift, Map.get(assigns, :explicit_project))

    assigns =
      assigns
      |> assign(:codex_model_options, [{"Use Codex default", ""} | ModelCatalog.model_options()])
      |> assign(:codex_approval_policy_options, Schema.codex_approval_policies())
      |> assign(:legacy_instance_drift, legacy_drift)
      |> assign(:selected_legacy_source, selected_source)
      |> assign_new(:legacy_reconciliation_notice, fn -> nil end)
      |> assign(
        :codex_reasoning_effort_options,
        [{"Use selected model or Codex default", ""} | ModelCatalog.reasoning_effort_options(selected_model)]
      )

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

      <%= if @workflow_validation_visible? && map_size(@workflow_field_errors) > 0 do %>
        <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
          <h3>Field errors</h3>
          <p>Fix the highlighted field values, then save again. These are local field format issues, not workflow semantics.</p>
        </aside>
      <% end %>
      <%= if @workflow_validation_visible? && @workflow_validation_error do %>
        <p class="error-copy"><strong>Configuration check failed:</strong> <%= @workflow_validation_error %></p>
        <.settings_check_summary targets={@workflow_check_targets} current_tab={:runtime} />
      <% end %>
      <%= if @workflow_save_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @workflow_save_notice.title %></strong>
          <span><%= @workflow_save_notice.message %></span>
        </aside>
      <% end %>

      <%= if @legacy_instance_drift do %>
        <aside class="setup-guidance-card setup-guidance-card-warning legacy-instance-drift" role="status" aria-live="polite">
          <h3>Legacy instance settings differ across projects</h3>
          <p>Select the source project in the Settings project selector. Symphony will not choose a source automatically.</p>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Instance key</th><th>Contributing projects</th></tr></thead>
              <tbody>
                <tr :for={entry <- @legacy_instance_drift.paths}>
                  <td class="mono"><%= entry.path %></td>
                  <td>
                    <div :for={contributor <- entry.contributors}>
                      <strong><%= contributor.project_slug %></strong>: <span class="mono"><%= contributor.value %></span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@selected_legacy_source} class="status-note">Selected source: <strong><%= @selected_legacy_source %></strong></p>
          <p :if={!@selected_legacy_source} class="error-copy">Choose one of the contributing projects before reconciling.</p>
          <button
            type="button"
            class="subtle-button"
            phx-click="reconcile_legacy_instance_workflow"
            disabled={is_nil(@selected_legacy_source)}
            phx-disable-with="Reconciling..."
          >Use selected project's instance settings</button>
        </aside>
      <% end %>

      <%= if @legacy_reconciliation_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@legacy_reconciliation_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @legacy_reconciliation_notice.title %></strong>
          <span><%= @legacy_reconciliation_notice.message %></span>
        </aside>
      <% end %>

      <form class="workflow-form settings-editor-form runtime-settings-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
        <div class="workflow-form-header settings-action-row">
          <div>
            <h2 class="section-title">Codex Runtime</h2>
            <p class="metric-label">Runtime source: <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span> <span class="muted mono"><%= @runtime_workflow_source.detail %></span></p>
          </div>
          <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save runtime settings</button>
        </div>

        <section class="workflow-form-section">
          <h3>Workspace</h3>
          <div class="workflow-profile-field-grid">
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="workspace_root" label="Workspace root" />
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="workspace_repository_base_root" label="Repository base root" />
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="workspace_worktree_base_root" label="Worktree base root" />
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="initialize_timeout_ms" label="Initialization timeout (ms)" type="number" />
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="workspace_min_free_gib" label="Minimum free disk (GiB)" type="number" step="0.1" />
          </div>
        </section>

        <section class="workflow-form-section">
          <h3>Lifecycle hooks</h3>
          <div class="workflow-profile-field-grid">
            <.text_area form={@workflow_form} name="hook_after_create" label="After create" />
            <.text_area form={@workflow_form} name="hook_before_run" label="Before run" />
            <.text_area form={@workflow_form} name="hook_after_run" label="After run" />
            <.text_area form={@workflow_form} name="hook_before_remove" label="Before remove" />
            <.text_field form={@workflow_form} errors={@workflow_field_errors} name="hook_timeout_ms" label="Hook timeout (ms)" type="number" />
          </div>
        </section>

        <section class="workflow-form-section">
          <h3>Codex</h3>
          <div class="workflow-profile-field-grid">
            <div class={field_class(@workflow_field_errors, @workflow_check_targets, :codex_model, "codex_model")}>
              <label class={field_title_class(@workflow_field_errors, @workflow_check_targets, :codex_model, "codex_model")} for="workflow-codex-model">Codex model</label>
              <select id="workflow-codex-model" name="workflow[codex_model]" aria-invalid={field_invalid?(@workflow_field_errors, @workflow_check_targets, :codex_model, "codex_model")}>
                <option :for={{label, value} <- @codex_model_options} value={value} selected={Map.get(@workflow_form, "codex_model", "") == value}><%= label %></option>
              </select>
              <p :if={Map.has_key?(@workflow_field_errors, "codex_model")} class="settings-check-message"><%= @workflow_field_errors["codex_model"] %></p>
              <.settings_check_messages targets={@workflow_check_targets} tab={:runtime} field={:codex_model} />
            </div>

            <div class={field_class(@workflow_field_errors, @workflow_check_targets, :codex_reasoning_effort, "codex_reasoning_effort")}>
              <label class={field_title_class(@workflow_field_errors, @workflow_check_targets, :codex_reasoning_effort, "codex_reasoning_effort")} for="workflow-codex-reasoning-effort">Reasoning effort</label>
              <select id="workflow-codex-reasoning-effort" name="workflow[codex_reasoning_effort]" aria-invalid={field_invalid?(@workflow_field_errors, @workflow_check_targets, :codex_reasoning_effort, "codex_reasoning_effort")}>
                <option :for={{label, value} <- @codex_reasoning_effort_options} value={value} selected={Map.get(@workflow_form, "codex_reasoning_effort", "") == value}><%= label %></option>
              </select>
              <p :if={Map.has_key?(@workflow_field_errors, "codex_reasoning_effort")} class="settings-check-message"><%= @workflow_field_errors["codex_reasoning_effort"] %></p>
              <.settings_check_messages targets={@workflow_check_targets} tab={:runtime} field={:codex_reasoning_effort} />
            </div>

            <label class="settings-field">
              <span class="metric-label">Approval policy</span>
              <select name="workflow[codex_approval_policy]">
                <option :for={value <- @codex_approval_policy_options} value={value} selected={@workflow_form["codex_approval_policy"] == value}><%= value %></option>
              </select>
            </label>

            <label class="settings-field">
              <span class="metric-label">Thread sandbox</span>
              <select name="workflow[codex_thread_sandbox]">
                <option value="workspace-write" selected={@workflow_form["codex_thread_sandbox"] == "workspace-write"}>workspace-write</option>
                <option value="danger-full-access" selected={@workflow_form["codex_thread_sandbox"] == "danger-full-access"}>danger-full-access</option>
              </select>
            </label>

            <label class="settings-field">
              <span class="metric-label">Turn sandbox</span>
              <select name="workflow[codex_turn_sandbox_preset]">
                <option value="workspace_write_no_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_no_network"}>workspace write, no network</option>
                <option value="workspace_write_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_network"}>workspace write, network enabled</option>
                <option value="danger_full_access" selected={@workflow_form["codex_turn_sandbox_preset"] == "danger_full_access"}>danger full access</option>
                <option value="custom" selected={@workflow_form["codex_turn_sandbox_preset"] == "custom"}>custom JSON</option>
              </select>
            </label>

            <label :if={@workflow_form["codex_turn_sandbox_preset"] == "custom"} class="settings-field">
              <span class="metric-label">Custom turn sandbox JSON</span>
              <textarea name="workflow[codex_turn_sandbox_json]" rows="6"><%= @workflow_form["codex_turn_sandbox_json"] %></textarea>
              <span :if={@workflow_field_errors["codex_turn_sandbox_json"]} class="settings-check-message"><%= @workflow_field_errors["codex_turn_sandbox_json"] %></span>
            </label>
          </div>
        </section>
      </form>
    </section>
    """
  end

  defp field_class(errors, targets, target_field, field) do
    ["settings-field", if(invalid?(errors, targets, target_field, field), do: "settings-check-invalid")]
  end

  defp field_title_class(errors, targets, target_field, field) do
    ["metric-label", if(invalid?(errors, targets, target_field, field), do: "settings-check-title-invalid")]
  end

  defp field_invalid?(errors, targets, target_field, field), do: invalid?(errors, targets, target_field, field)

  defp invalid?(errors, targets, target_field, field) do
    Map.has_key?(errors, field) or SettingsCheck.invalid?(targets, :runtime, target_field)
  end

  attr(:form, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:step, :string, default: nil)

  defp text_field(assigns) do
    ~H"""
    <label class={["settings-field", if(@errors[@name], do: "settings-check-invalid")] }>
      <span class={["metric-label", if(@errors[@name], do: "settings-check-title-invalid")] }><%= @label %></span>
      <input type={@type} step={@step} name={"workflow[#{@name}]"} value={@form[@name]} aria-invalid={!is_nil(@errors[@name])} />
      <span :if={@errors[@name]} class="settings-check-message"><%= @errors[@name] %></span>
    </label>
    """
  end

  attr(:form, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)

  defp text_area(assigns) do
    ~H"""
    <label class="settings-field">
      <span class="metric-label"><%= @label %></span>
      <textarea name={"workflow[#{@name}]"} rows="4"><%= @form[@name] %></textarea>
    </label>
    """
  end

  defp selected_drift_source(nil, _project), do: nil
  defp selected_drift_source(_drift, nil), do: nil

  defp selected_drift_source(drift, project) do
    slug = ProjectSettings.value(project, :slug)
    if Enum.any?(drift.projects, &(&1.slug == slug)), do: slug
  end
end
