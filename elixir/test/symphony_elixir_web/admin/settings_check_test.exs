defmodule SymphonyElixirWeb.Admin.SettingsCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Admin.SettingsCheck

  test "targets workflow state and transition validation messages" do
    draft = %{
      "workflow_states" => %{"Ready" => %{}, "In Progress" => %{}},
      "allowed_transitions" => [
        %{"from" => "Ready", "to" => "In Progress", "actor" => "codex"}
      ]
    }

    state_targets = SettingsCheck.workflow_check_targets(draft, ~s(states."Ready" references invalid configuration))
    assert Enum.any?(state_targets, &match?(%{tab: :workflow, field: :workflow_state, scope: "Ready"}, &1))

    transition_targets = SettingsCheck.workflow_check_targets(draft, ~s(allowed_transitions.from references unknown workflow state "Ready"))

    assert Enum.any?(
             transition_targets,
             &match?(%{tab: :workflow, field: :allowed_transition, scope: 0, title: "Allowed transition 1"}, &1)
           )
  end

  test "targets agent profile fields and panel" do
    targets =
      SettingsCheck.workflow_check_targets(
        %{},
        ~s(workflow profiles.implementation.allowed_updates.target_states references unknown state "Review")
      )

    assert Enum.any?(targets, &match?(%{tab: :agents, field: :profile_target_states, scope: "implementation"}, &1))
    assert Enum.any?(targets, &match?(%{tab: :agents, field: :profile_panel, scope: "implementation"}, &1))
    assert SettingsCheck.invalid?(targets, :agents, :profile_target_states, "implementation")
    assert SettingsCheck.messages(targets, :agents, :profile_target_states, "implementation") != []
  end

  test "returns stable css classes for invalid settings and project items" do
    targets = [%{tab: :workflow, field: :active_states, scope: nil, title: "Active states", message: "bad"}]

    assert SettingsCheck.class(targets, :workflow, :active_states) == ["settings-field", "settings-check-invalid"]
    assert SettingsCheck.title_class(targets, :workflow, :active_states) == ["metric-label", "settings-check-title-invalid"]
    assert SettingsCheck.class(targets, :workflow, :terminal_states) == ["settings-field", nil]

    items = [%{title: "Repository URL"}]
    assert SettingsCheck.project_field_class(items, "Repository URL") == ["settings-field", "settings-check-invalid"]
    assert SettingsCheck.project_field_title_class(items, "Repository URL") == ["metric-label", "settings-check-title-invalid"]
  end
end
