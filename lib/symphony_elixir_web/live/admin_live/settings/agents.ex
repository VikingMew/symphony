defmodule SymphonyElixirWeb.AdminLive.Settings.Agents do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.SettingsShell,
    only: [settings_check_messages: 1, settings_check_summary: 1]

  alias SymphonyElixir.ProfilePromptSummary
  alias SymphonyElixirWeb.Admin.{ObservabilityPresenter, SettingsCheck}
  alias SymphonyElixirWeb.AdminLive.WorkflowState

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card settings-content-card">
      <h2 class="section-title">Agents</h2>
      <p class="metric-label">
        Runtime source:
        <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span>
        <span class="muted mono"><%= @runtime_workflow_source.detail %></span>
      </p>
      <%= if @workflow_validation_visible? && map_size(@workflow_field_errors) > 0 do %>
        <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
          <h3>Field errors</h3>
          <p>Fix the highlighted field values, then save again. These are local field format issues, not workflow semantics.</p>
        </aside>
      <% end %>
      <%= if @workflow_validation_visible? && @workflow_validation_error do %>
        <p class="error-copy"><strong>Configuration check failed:</strong> <%= @workflow_validation_error %></p>
        <.settings_check_summary targets={@workflow_check_targets} current_tab={:agents} />
      <% end %>
      <%= if @workflow_save_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @workflow_save_notice.title %></strong>
          <span><%= @workflow_save_notice.message %></span>
        </aside>
      <% end %>

      <form class="workflow-form settings-editor-form agent-settings-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
        <div class="workflow-form-header settings-action-row">
          <div>
            <h2 class="section-title">Profile Configuration</h2>
            <p class="metric-label">Edit agent execution profiles, prompt composition, update permissions, and target states.</p>
          </div>
          <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save agent settings</button>
        </div>

        <div class="workflow-summary-grid">
          <p><span class="metric-label">Profiles</span><strong><%= @workflow_form_summary.profiles %></strong></p>
          <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
          <% prompt_page_summary = profile_prompt_page_summary(@workflow_form) %>
          <p><span class="metric-label">Base prompt</span><strong><%= prompt_page_summary.base_chars %> chars</strong></p>
          <p><span class="metric-label">Profile templates</span><strong><%= prompt_page_summary.profiles_with_templates %></strong></p>
          <p><span class="metric-label">Prompt warnings</span><strong><%= prompt_page_summary.profiles_with_warnings %></strong></p>
        </div>

        <section class="workflow-form-section agent-prompt-editor">
          <div class="agent-section-heading">
            <div>
              <h3>Base Prompt</h3>
              <p class="workflow-help-copy">Shared task template used by profile prompts unless a profile replaces it.</p>
            </div>
            <span class="status-badge status-info">shared</span>
          </div>
          <div class="agent-field agent-field-full">
            <label class="agent-field-label" for="workflow-prompt-body">Base prompt</label>
            <textarea id="workflow-prompt-body" class="workflow-textbox workflow-textbox-prompt" name="workflow[prompt_body]" rows="12"><%= @workflow_form["prompt_body"] %></textarea>
          </div>
        </section>

        <section class="workflow-form-section agent-profiles-section">
          <div class="agent-section-heading">
            <div>
              <h3>Profiles</h3>
              <p class="workflow-help-copy">Each profile defines one stage-specific agent policy.</p>
            </div>
          </div>
          <div class="workflow-profile-grid">
            <article :for={{profile_id, profile} <- profile_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :agents, :profile_panel, profile_id, "workflow-profile-panel")}>
              <% prompt_summary = profile_prompt_summary(@workflow_form, profile_id, profile) %>
              <header class="workflow-profile-header">
                <div>
                  <h4 class={settings_check_title_class(@workflow_check_targets, :agents, :profile_panel, profile_id)}><%= profile["name"] || profile_id %></h4>
                  <p class="metric-label mono"><%= profile_id %></p>
                </div>
                <div class="workflow-profile-badges">
                  <span class="status-badge status-info"><%= profile["executor_type"] %></span>
                  <span class="status-badge"><%= profile["prompt_mode"] %></span>
                </div>
              </header>

              <div class="workflow-profile-field-grid">
                <section class="profile-field-group">
                  <h5>Identity</h5>
                  <div class={settings_check_class(@workflow_check_targets, :agents, :profile_name, profile_id, "agent-field")}>
                    <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_name, profile_id, "agent-field-label")} for={"profile-#{profile_id}-name"}>Name</label>
                    <input id={"profile-#{profile_id}-name"} name={"workflow[profiles][#{profile_id}][name]"} value={profile["name"]} aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_name, profile_id)} />
                    <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_name} scope={profile_id} />
                  </div>
                </section>

                <section class="profile-field-group">
                  <h5>Execution</h5>
                  <div class={settings_check_class(@workflow_check_targets, :agents, :profile_executor, profile_id, "agent-field")}>
                    <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_executor, profile_id, "agent-field-label")} for={"profile-#{profile_id}-executor"}>Executor</label>
                    <select id={"profile-#{profile_id}-executor"} name={"workflow[profiles][#{profile_id}][executor_type]"}>
                      <option value="codex_agent" selected={profile["executor_type"] == "codex_agent"}>codex_agent</option>
                      <option value="backend_action" selected={profile["executor_type"] == "backend_action"}>backend_action</option>
                      <option value="manual" selected={profile["executor_type"] == "manual"}>manual</option>
                      <option value="external_worker" selected={profile["executor_type"] == "external_worker"}>external_worker</option>
                    </select>
                    <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_executor} scope={profile_id} />
                  </div>
                </section>

                <section class="profile-field-group profile-field-group-prompt">
                  <h5>Prompt</h5>
                  <div class="profile-prompt-guidance">
                    <div class="profile-prompt-metrics">
                      <span><strong><%= prompt_summary.template_chars %></strong> template chars</span>
                      <span><strong><%= format_prompt_chars(prompt_summary.effective_chars) %></strong> effective chars</span>
                      <span><%= if prompt_summary.uses_base_prompt?, do: "Base Prompt used", else: "Base Prompt not used" %></span>
                    </div>
                    <p class="metric-detail"><%= prompt_summary.composition %></p>
                    <p :if={prompt_summary.warning} class="error-copy"><%= prompt_summary.warning %></p>
                    <details class="profile-prompt-preview">
                      <summary>Preview effective prompt</summary>
                      <pre class="inline-code-panel"><%= truncate(prompt_summary.preview, 1_200) %></pre>
                    </details>
                  </div>
                  <div class="profile-prompt-layout">
                    <div class={settings_check_class(@workflow_check_targets, :agents, :profile_prompt_mode, profile_id, "agent-field profile-prompt-mode-field")}>
                      <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_prompt_mode, profile_id, "agent-field-label")} for={"profile-#{profile_id}-prompt-mode"}>Prompt mode</label>
                      <select id={"profile-#{profile_id}-prompt-mode"} name={"workflow[profiles][#{profile_id}][prompt_mode]"}>
                        <option value="extend" selected={profile["prompt_mode"] == "extend"}>extend</option>
                        <option value="replace" selected={profile["prompt_mode"] == "replace"}>replace</option>
                        <option value="disabled" selected={profile["prompt_mode"] == "disabled"}>disabled</option>
                      </select>
                      <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_prompt_mode} scope={profile_id} />
                    </div>
                    <div class={settings_check_class(@workflow_check_targets, :agents, :profile_prompt_template, profile_id, "agent-field agent-field-full")}>
                      <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_prompt_template, profile_id, "agent-field-label")} for={"profile-#{profile_id}-prompt-template"}>Profile prompt template</label>
                      <textarea id={"profile-#{profile_id}-prompt-template"} class="workflow-textbox workflow-textbox-profile" name={"workflow[profiles][#{profile_id}][prompt_template]"} rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_prompt_template, profile_id)}><%= profile["prompt_template"] %></textarea>
                      <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_prompt_template} scope={profile_id} />
                    </div>
                  </div>
                </section>

                <section class="profile-field-group">
                  <h5>Updates</h5>
                  <div class="workflow-checkbox-row">
                    <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_description]"} value="false" />
                    <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_description]"} value="true" checked={profile["allow_description"] == "true"} /> Description</label>
                    <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_comment]"} value="false" />
                    <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_comment]"} value="true" checked={profile["allow_comment"] == "true"} /> Comment</label>
                    <input type="hidden" name={"workflow[profiles][#{profile_id}][allow_result]"} value="false" />
                    <label><input type="checkbox" name={"workflow[profiles][#{profile_id}][allow_result]"} value="true" checked={profile["allow_result"] == "true"} /> Result</label>
                  </div>
                </section>

                <section class="profile-field-group">
                  <h5>Routing</h5>
                  <div class={settings_check_class(@workflow_check_targets, :agents, :profile_target_states, profile_id, "agent-field")}>
                    <label class={settings_check_title_class(@workflow_check_targets, :agents, :profile_target_states, profile_id, "agent-field-label")} for={"profile-#{profile_id}-target-states"}>Allowed target states</label>
                    <textarea id={"profile-#{profile_id}-target-states"} class="workflow-textbox workflow-textbox-compact" name={"workflow[profiles][#{profile_id}][target_states]"} rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :agents, :profile_target_states, profile_id)}><%= profile["target_states"] %></textarea>
                    <.settings_check_messages targets={@workflow_check_targets} tab={:agents} field={:profile_target_states} scope={profile_id} />
                  </div>
                </section>
              </div>
            </article>
          </div>
        </section>
      </form>
    </section>
    <section class="section-card">
      <h2 class="section-title">Version History</h2>
      <%= if WorkflowState.section_versions(@workflow_versions, :agents) == [] do %>
        <p class="empty-state">No agent settings versions yet.</p>
      <% else %>
        <table class="data-table">
          <thead><tr><th>Version</th><th>Source</th><th>Active</th><th>Created</th><th></th></tr></thead>
          <tbody>
            <tr :for={version <- WorkflowState.section_versions(@workflow_versions, :agents)}>
              <td><%= version.version %></td>
              <td><%= version.source %></td>
              <td><%= version.active %></td>
              <td class="mono"><%= ObservabilityPresenter.fmt_dt(version.inserted_at) %></td>
              <td>
                <button class="subtle-button" phx-click="restore_settings_version" phx-value-id={version.id} phx-disable-with="Restoring...">Restore agent settings</button>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  defp profile_entries(form) do
    form
    |> Map.get("profiles", %{})
    |> Enum.sort_by(fn {profile_id, _profile} -> profile_id end)
  end

  defp profile_prompt_page_summary(form) do
    ProfilePromptSummary.page_summary(Map.get(form, "prompt_body", ""), Map.get(form, "profiles", %{}))
  end

  defp profile_prompt_summary(form, profile_id, profile) do
    ProfilePromptSummary.profile_summary(Map.get(form, "prompt_body", ""), profile_id, profile)
  end

  defp format_prompt_chars(nil), do: "n/a"
  defp format_prompt_chars(chars), do: "#{chars}"

  defp settings_check_class(targets, tab, field, scope, base) do
    SettingsCheck.class(targets, tab, field, scope, base)
  end

  defp settings_check_title_class(targets, tab, field, scope) do
    settings_check_title_class(targets, tab, field, scope, "metric-label")
  end

  defp settings_check_title_class(targets, tab, field, scope, base) do
    SettingsCheck.title_class(targets, tab, field, scope, base)
  end

  defp settings_check_invalid?(targets, tab, field, scope) do
    SettingsCheck.invalid?(targets, tab, field, scope)
  end

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "\n... truncated"
  end

  defp truncate(value, _limit), do: value
end
