defmodule SymphonyElixirWeb.AdminLive.Settings.Workflow do
  @moduledoc false

  use Phoenix.Component

  import SymphonyElixirWeb.AdminLive.Settings.WorkflowDiscovery,
    only: [linear_workflow_discovery: 1]

  import SymphonyElixirWeb.AdminLive.Settings.Components,
    only: [settings_check_messages: 1, settings_check_summary: 1]

  alias SymphonyElixir.{Config, WorkflowForm}
  alias SymphonyElixirWeb.Admin.{ProjectSettings, SettingsCheck}

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="section-card">
      <h2 class="section-title">Workflow</h2>
      <p class="metric-label">
        Runtime source:
        <span class="status-badge status-info"><%= @runtime_workflow_source.type %></span>
        <span class="muted mono"><%= @runtime_workflow_source.detail %></span>
      </p>
      <%= if @workflow_setup_required do %>
        <p class="empty-state">No workflow is configured yet. Fill the structured draft below.</p>
      <% end %>
      <%= if @workflow_configuration_items != [] do %>
        <aside class="setup-guidance-card" role="status" aria-live="polite">
          <h3>Workflow configuration checklist</h3>
          <ul>
            <li :for={item <- @workflow_configuration_items}>
              <div class="setup-guidance-item-heading">
                <span class="status-badge status-info"><%= item.scope %></span>
                <strong><%= item.title %></strong>
              </div>
              <span><%= item.detail %></span>
              <a :if={item.href} class="issue-link" href={item.href}><%= item.action %></a>
            </li>
          </ul>
        </aside>
      <% end %>
      <.linear_workflow_discovery discovery={@linear_discovery} draft={@workflow_form} />
      <%= if @workflow_diagnostics_notice do %>
        <p class="empty-state">
          <%= @workflow_diagnostics_notice %>
          <a class="issue-link" href="/diagnostics/linear">Open Linear diagnostics</a>
        </p>
      <% end %>
      <%= if @workflow_validation_visible? && map_size(@workflow_field_errors) > 0 do %>
        <aside class="setup-guidance-card setup-guidance-card-warning" role="status" aria-live="polite">
          <h3>Field errors</h3>
          <p>Fix the highlighted field values, then save again. These are local field format issues, not workflow semantics.</p>
          <ul>
            <li :for={{field, message} <- @workflow_field_errors}>
              <a class="issue-link" href={"##{workflow_field_id(field)}"}><%= workflow_field_label(field) %></a>
              <span><%= message %></span>
            </li>
          </ul>
        </aside>
      <% end %>
      <%= if @workflow_validation_visible? && @workflow_validation_error do %>
        <p class="error-copy"><strong>Configuration check failed:</strong> <%= @workflow_validation_error %></p>
        <.settings_check_summary targets={@workflow_check_targets} current_tab={:workflow} />
      <% end %>
      <%= if @workflow_save_notice do %>
        <aside class={["workflow-save-toast", "workflow-save-toast-#{@workflow_save_notice.level}"]} role="status" aria-live="polite">
          <strong><%= @workflow_save_notice.title %></strong>
          <span><%= @workflow_save_notice.message %></span>
        </aside>
      <% end %>
      <form class="workflow-form" phx-change="validate_workflow_form" phx-submit="save_workflow_form" novalidate>
        <div class="workflow-form-header">
          <div>
            <h2 class="section-title">Draft Configuration</h2>
            <p class="metric-label">Edit fields, review validation, then save the current database workflow.</p>
          </div>
          <button class="subtle-button" type="submit" phx-disable-with="Saving...">Save workflow</button>
        </div>

        <div class="workflow-summary-grid">
          <p><span class="metric-label">Tracker</span><strong><%= @workflow_form_summary.tracker %></strong></p>
          <p><span class="metric-label">Active states</span><strong><%= @workflow_form_summary.active_states %></strong></p>
          <p><span class="metric-label">Terminal states</span><strong><%= @workflow_form_summary.terminal_states %></strong></p>
          <p><span class="metric-label">Hooks</span><strong><%= @workflow_form_summary.hooks %></strong></p>
          <p><span class="metric-label">Setup commands</span><strong><%= @workflow_form_summary.setup_commands %></strong></p>
          <p><span class="metric-label">Routed states</span><strong><%= @workflow_form_summary.routed_states %></strong></p>
        </div>

        <div class="workflow-form-grid">
          <section class={settings_check_class(@workflow_check_targets, :workflow, :tracker_section, nil, "workflow-form-section")}>
            <h3 class={settings_check_title_class(@workflow_check_targets, :workflow, :tracker_section)}>Tracker</h3>
            <p class="metric-label">Linear tracker is managed by shared runtime configuration. Project-specific Linear slugs are configured in Settings / Projects.</p>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :tracker_assignee)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :tracker_assignee)}>Assignee</span><input name="workflow[tracker_assignee]" value={@workflow_form["tracker_assignee"]} /></label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :active_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :active_states)}>Active states</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[active_states]" rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :active_states)}><%= @workflow_form["active_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:active_states} /></label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :terminal_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :terminal_states)}>Terminal states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[terminal_states]" rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :terminal_states)}><%= @workflow_form["terminal_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:terminal_states} /></label>
          </section>

          <section class="workflow-form-section">
            <h3>Bootstrap</h3>
            <p class="metric-label">Project checkout source is configured per project in Settings / Projects.</p>
            <label>
              <span class="metric-label">Initialize timeout ms</span>
              <input id={workflow_field_id("initialize_timeout_ms")} class={workflow_field_class(@workflow_field_errors, "initialize_timeout_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "initialize_timeout_ms")} type="number" min="1" name="workflow[initialize_timeout_ms]" value={@workflow_form["initialize_timeout_ms"]} />
              <.workflow_field_error field="initialize_timeout_ms" errors={@workflow_field_errors} />
            </label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :setup_commands)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :setup_commands)}>Setup commands</span><textarea class="workflow-textbox workflow-textbox-medium" name="workflow[project_setup_commands]" rows="5" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :setup_commands)}><%= @workflow_form["project_setup_commands"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:setup_commands} /></label>
            <label><span class="metric-label">Cleanup commands</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[project_cleanup_commands]" rows="4"><%= @workflow_form["project_cleanup_commands"] %></textarea></label>
          </section>

          <section class="workflow-form-section">
            <h3>Lifecycle Hooks</h3>
            <p class="workflow-help-copy">
              Hooks execute shell commands in the issue workspace after initialization. Project checkout and setup use Initialize timeout ms, then after_create runs with the hook timeout below.
            </p>
            <label>
              <span class="metric-label">Hook timeout ms</span>
              <input id={workflow_field_id("hook_timeout_ms")} class={workflow_field_class(@workflow_field_errors, "hook_timeout_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "hook_timeout_ms")} type="number" min="1" name="workflow[hook_timeout_ms]" value={@workflow_form["hook_timeout_ms"]} />
              <.workflow_field_error field="hook_timeout_ms" errors={@workflow_field_errors} />
            </label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_after_create)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_after_create)}>after_create</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_create]" rows="4"><%= @workflow_form["hook_after_create"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_after_create} /></label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_before_run)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_before_run)}>before_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_run]" rows="3"><%= @workflow_form["hook_before_run"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_before_run} /></label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_after_run)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_after_run)}>after_run</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_after_run]" rows="3"><%= @workflow_form["hook_after_run"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_after_run} /></label>
            <label class={settings_check_class(@workflow_check_targets, :workflow, :hook_before_remove)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :hook_before_remove)}>before_remove</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[hook_before_remove]" rows="3"><%= @workflow_form["hook_before_remove"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:hook_before_remove} /></label>
          </section>

          <section class="workflow-form-section">
            <h3>Runtime</h3>
            <label><span class="metric-label">Clone workspace root</span><input name="workflow[workspace_root]" value={@workflow_form["workspace_root"]} /></label>
            <label><span class="metric-label">Repository base root</span><input name="workflow[workspace_repository_base_root]" value={@workflow_form["workspace_repository_base_root"]} placeholder="Defaults to clone workspace root/repositories" /></label>
            <label><span class="metric-label">Worktree base root</span><input name="workflow[workspace_worktree_base_root]" value={@workflow_form["workspace_worktree_base_root"]} placeholder="Defaults to clone workspace root/worktrees" /></label>
            <label>
              <span class="metric-label">Minimum free GiB</span>
              <input id={workflow_field_id("workspace_min_free_gib")} class={workflow_field_class(@workflow_field_errors, "workspace_min_free_gib")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "workspace_min_free_gib")} type="number" min="0" step="0.1" name="workflow[workspace_min_free_gib]" value={@workflow_form["workspace_min_free_gib"]} />
              <.workflow_field_error field="workspace_min_free_gib" errors={@workflow_field_errors} />
            </label>
            <div class="settings-derived-preview">
              <span class="metric-label">Derived paths</span>
              <code><%= ProjectSettings.repository_preview(@workflow_form, @projects) %></code>
              <code><%= ProjectSettings.worktree_preview(@workflow_form) %></code>
            </div>
            <label>
              <span class="metric-label">Polling interval ms</span>
              <input id={workflow_field_id("polling_interval_ms")} class={workflow_field_class(@workflow_field_errors, "polling_interval_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "polling_interval_ms")} type="number" min="1" name="workflow[polling_interval_ms]" value={@workflow_form["polling_interval_ms"]} />
              <.workflow_field_error field="polling_interval_ms" errors={@workflow_field_errors} />
            </label>
            <label>
              <span class="metric-label">Max agents</span>
              <input id={workflow_field_id("agent_max_concurrent_agents")} class={workflow_field_class(@workflow_field_errors, "agent_max_concurrent_agents")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "agent_max_concurrent_agents")} type="number" min="1" name="workflow[agent_max_concurrent_agents]" value={@workflow_form["agent_max_concurrent_agents"]} />
              <.workflow_field_error field="agent_max_concurrent_agents" errors={@workflow_field_errors} />
            </label>
            <label>
              <span class="metric-label">Max turns</span>
              <input id={workflow_field_id("agent_max_turns")} class={workflow_field_class(@workflow_field_errors, "agent_max_turns")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "agent_max_turns")} type="number" min="1" name="workflow[agent_max_turns]" value={@workflow_form["agent_max_turns"]} />
              <.workflow_field_error field="agent_max_turns" errors={@workflow_field_errors} />
            </label>
          </section>

          <section class="workflow-form-section">
            <h3>Codex</h3>
            <label><span class="metric-label">Command</span><input name="workflow[codex_command]" value={@workflow_form["codex_command"]} /></label>
            <label>
              <span class="metric-label">Pre-start commands</span>
              <textarea class="workflow-textbox workflow-textbox-compact" name="workflow[codex_pre_start_commands]" rows="4" placeholder="source ~/.nvs/nvs.sh&#10;nvs use 22 &gt;/dev/null"><%= @workflow_form["codex_pre_start_commands"] %></textarea>
            </label>
            <label>
              <span class="metric-label">Approval policy</span>
              <select name="workflow[codex_approval_policy]">
                <option :for={policy <- Config.Schema.codex_approval_policies()} value={policy} selected={@workflow_form["codex_approval_policy"] == policy}><%= policy %></option>
              </select>
            </label>
            <label>
              <span class="metric-label">Thread sandbox</span>
              <input name="workflow[codex_thread_sandbox]" value={@workflow_form["codex_thread_sandbox"]} />
              <span class="settings-help">Thread startup policy. Turn sandbox below controls per-turn file and network access.</span>
            </label>
            <label>
              <span class="metric-label">Turn sandbox</span>
              <select name="workflow[codex_turn_sandbox_preset]">
                <option value="workspace_write_no_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_no_network"}>Workspace write, no network</option>
                <option value="workspace_write_network" selected={@workflow_form["codex_turn_sandbox_preset"] == "workspace_write_network"}>Workspace write, network enabled</option>
                <option value="danger_full_access" selected={@workflow_form["codex_turn_sandbox_preset"] == "danger_full_access"}>Danger full access</option>
                <option value="custom" selected={@workflow_form["codex_turn_sandbox_preset"] == "custom"}>Custom JSON</option>
              </select>
              <span class="settings-help">This is sent as Codex turn/start sandboxPolicy. Use network enabled or danger full access when agent turns must push or fetch.</span>
            </label>
            <label>
              <span class="metric-label">Custom turn sandbox JSON</span>
              <textarea id={workflow_field_id("codex_turn_sandbox_json")} class={["workflow-textbox workflow-textbox-compact", workflow_field_class(@workflow_field_errors, "codex_turn_sandbox_json")]} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "codex_turn_sandbox_json")} name="workflow[codex_turn_sandbox_json]" rows="6" placeholder={~s({"type":"workspaceWrite","networkAccess":true})}><%= @workflow_form["codex_turn_sandbox_json"] %></textarea>
              <.workflow_field_error field="codex_turn_sandbox_json" errors={@workflow_field_errors} />
            </label>
            <label class="checkbox-row">
              <input type="hidden" name="workflow[codex_rate_limit_gate_enabled]" value="false" />
              <input type="checkbox" name="workflow[codex_rate_limit_gate_enabled]" value="true" checked={@workflow_form["codex_rate_limit_gate_enabled"] == "true"} />
              <span>Pause new sessions when Codex rate-limit headroom is low</span>
            </label>
            <label>
              <span class="metric-label">5-hour minimum remaining %</span>
              <input id={workflow_field_id("codex_rate_limit_gate_5h_threshold_percent")} class={workflow_field_class(@workflow_field_errors, "codex_rate_limit_gate_5h_threshold_percent")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "codex_rate_limit_gate_5h_threshold_percent")} type="number" min="0" max="100" step="0.1" name="workflow[codex_rate_limit_gate_5h_threshold_percent]" value={@workflow_form["codex_rate_limit_gate_5h_threshold_percent"]} />
              <.workflow_field_error field="codex_rate_limit_gate_5h_threshold_percent" errors={@workflow_field_errors} />
            </label>
            <label>
              <span class="metric-label">7-day / 1-week minimum remaining %</span>
              <input id={workflow_field_id("codex_rate_limit_gate_7d_threshold_percent")} class={workflow_field_class(@workflow_field_errors, "codex_rate_limit_gate_7d_threshold_percent")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "codex_rate_limit_gate_7d_threshold_percent")} type="number" min="0" max="100" step="0.1" name="workflow[codex_rate_limit_gate_7d_threshold_percent]" value={@workflow_form["codex_rate_limit_gate_7d_threshold_percent"]} />
              <.workflow_field_error field="codex_rate_limit_gate_7d_threshold_percent" errors={@workflow_field_errors} />
            </label>
            <label>
              <span class="metric-label">Post-reset delay ms</span>
              <input id={workflow_field_id("codex_rate_limit_gate_post_reset_delay_ms")} class={workflow_field_class(@workflow_field_errors, "codex_rate_limit_gate_post_reset_delay_ms")} aria-invalid={workflow_field_invalid?(@workflow_field_errors, "codex_rate_limit_gate_post_reset_delay_ms")} type="number" min="0" step="1000" name="workflow[codex_rate_limit_gate_post_reset_delay_ms]" value={@workflow_form["codex_rate_limit_gate_post_reset_delay_ms"]} />
              <.workflow_field_error field="codex_rate_limit_gate_post_reset_delay_ms" errors={@workflow_field_errors} />
            </label>
          </section>
        </div>

        <section class="workflow-form-section">
          <h3>Workflow Phases / State Routing</h3>
          <div class="workflow-routing-grid">
            <label :for={{state, attrs} <- workflow_state_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :workflow, :workflow_state, state)}>
              <span class={settings_check_title_class(@workflow_check_targets, :workflow, :workflow_state, state)}><%= state %></span>
              <select name={"workflow[workflow_states][#{state}][profile]"}>
                <option value="">No profile</option>
                <option :for={profile <- WorkflowForm.profile_options(@workflow_form)} value={profile} selected={attrs["profile"] == profile}><%= profile %></option>
              </select>
              <.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:workflow_state} scope={state} />
            </label>
          </div>
          <label class={settings_check_class(@workflow_check_targets, :workflow, :human_review_states)}><span class={settings_check_title_class(@workflow_check_targets, :workflow, :human_review_states)}>Human review states</span><textarea class="workflow-textbox workflow-textbox-compact" name="workflow[human_review_states]" rows="4" aria-invalid={settings_check_invalid?(@workflow_check_targets, :workflow, :human_review_states)}><%= @workflow_form["human_review_states"] %></textarea><.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:human_review_states} /></label>
          <div>
            <div class="workflow-subsection-heading">
              <span class={settings_check_title_class(@workflow_check_targets, :workflow, :allowed_transitions)}>Allowed transitions</span>
              <button class="workflow-add-button" type="button" phx-click="add_workflow_transition" title="Add transition" aria-label="Add transition">+</button>
            </div>
            <div class="workflow-transition-grid">
              <div class="workflow-transition-header">From</div>
              <div class="workflow-transition-header">To</div>
              <div class="workflow-transition-header">Actor</div>
              <div class="workflow-transition-header">Profile</div>
              <div :for={{transition, index} <- transition_entries(@workflow_form)} class={settings_check_class(@workflow_check_targets, :workflow, :allowed_transition, index, "workflow-transition-row")}>
                <input name={"workflow[allowed_transitions][#{index}][from]"} value={transition["from"]} />
                <input name={"workflow[allowed_transitions][#{index}][to]"} value={transition["to"]} />
                <select name={"workflow[allowed_transitions][#{index}][actor]"}>
                  <option value="">Select</option>
                  <option value="codex" selected={transition["actor"] == "codex"}>codex</option>
                  <option value="human" selected={transition["actor"] == "human"}>human</option>
                  <option value="symphony" selected={transition["actor"] == "symphony"}>symphony</option>
                </select>
                <select name={"workflow[allowed_transitions][#{index}][profile]"}>
                  <option value="">No profile</option>
                  <option :for={profile <- WorkflowForm.profile_options(@workflow_form)} value={profile} selected={transition["profile"] == profile}><%= profile %></option>
                </select>
                <.settings_check_messages targets={@workflow_check_targets} tab={:workflow} field={:allowed_transition} scope={index} />
              </div>
            </div>
          </div>
        </section>
      </form>
    </section>
    """
  end

  attr(:field, :string, required: true)
  attr(:errors, :map, required: true)

  @spec workflow_field_error(map()) :: Phoenix.LiveView.Rendered.t()
  def workflow_field_error(assigns) do
    ~H"""
    <p :if={Map.has_key?(@errors, @field)} class="field-error">
      <%= Map.fetch!(@errors, @field) %>
    </p>
    """
  end

  defp workflow_state_entries(form) do
    form
    |> Map.get("workflow_states", %{})
    |> Enum.sort_by(fn {state, _attrs} -> state end)
  end

  defp transition_entries(form) do
    form
    |> Map.get("allowed_transitions", [])
    |> normalize_transition_entries()
    |> Enum.with_index()
  end

  defp normalize_transition_entries(entries) when is_list(entries), do: entries

  defp normalize_transition_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} ->
      case Integer.parse(to_string(index)) do
        {integer, ""} -> integer
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, entry} -> entry end)
  end

  defp normalize_transition_entries(_entries), do: []

  defp settings_check_class(targets, tab, field, scope \\ nil, base \\ "settings-field") do
    SettingsCheck.class(targets, tab, field, scope, base)
  end

  defp settings_check_title_class(targets, tab, field, scope \\ nil, base \\ "metric-label") do
    SettingsCheck.title_class(targets, tab, field, scope, base)
  end

  defp settings_check_invalid?(targets, tab, field) do
    SettingsCheck.invalid?(targets, tab, field, nil)
  end

  defp workflow_field_id(field), do: "workflow-field-#{String.replace(field, "_", "-")}"
  defp workflow_field_class(errors, field), do: if(workflow_field_invalid?(errors, field), do: "field-invalid")
  defp workflow_field_invalid?(errors, field), do: Map.has_key?(errors, field)
  defp workflow_field_label("polling_interval_ms"), do: "Polling interval ms"
  defp workflow_field_label("agent_max_concurrent_agents"), do: "Max agents"
  defp workflow_field_label("agent_max_turns"), do: "Max turns"
  defp workflow_field_label("hook_timeout_ms"), do: "Hook timeout ms"
  defp workflow_field_label("initialize_timeout_ms"), do: "Initialize timeout ms"
  defp workflow_field_label(field), do: field
end
