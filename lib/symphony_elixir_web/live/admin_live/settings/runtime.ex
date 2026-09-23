defmodule SymphonyElixirWeb.AdminLive.Settings.Runtime do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.Settings.Components,
    only: [settings_check_messages: 1, settings_check_summary: 1]

  alias SymphonyElixir.Codex.ModelCatalog
  alias SymphonyElixirWeb.Admin.SettingsCheck

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    workflow_form = Map.get(assigns, :workflow_form, %{})
    selected_model = Map.get(workflow_form, "codex_model", "")

    assigns =
      assigns
      |> assign(:codex_model_options, [{"Use Codex default", ""} | ModelCatalog.model_options()])
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

      <form class="workflow-form settings-editor-form runtime-settings-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
        <div class="workflow-form-header settings-action-row">
          <div>
            <h2 class="section-title">Codex Runtime</h2>
            <p class="metric-label">Runtime source: <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span> <span class="muted mono"><%= @runtime_workflow_source.detail %></span></p>
          </div>
          <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save runtime settings</button>
        </div>

        <section class="workflow-form-section">
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
end
