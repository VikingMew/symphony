# 165 Admin Live Settings Check Boundary

## Goal

Extract settings check target derivation and field-highlighting rules out of `AdminLive`.

## Status

Completed.

## Background

`AdminLive` has already had project settings extracted, but it still owns many settings validation display helpers:

- configuration missing/check target generation;
- workflow and profile target matching;
- field class/title class decisions;
- profile target title/message construction;
- tab path/label mapping;
- project/workflow field highlight helpers.

These helpers are presentation policy, not LiveView process logic. They are also reused across settings pages conceptually, but their ownership is buried in a very large LiveView.

## Scope

- Extract check-target derivation and field highlighting into a module such as `SymphonyElixirWeb.Admin.SettingsCheck`.
- Keep LiveView assigns and event handlers in `AdminLive`.
- Add focused tests for target generation, message matching, tab/field/scope matching, and CSS class decisions.
- Preserve existing rendered text and class names.

## Out of Scope

- Changing settings UX.
- Moving all settings pages out of `AdminLive`.
- Replacing semantic validation from `Config.Schema`.
- Updating long-term docs.

## Acceptance Criteria

- `AdminLive` no longer owns check target matching or field class decisions.
- Settings check behavior is testable without mounting the LiveView.
- Existing settings page tests continue to pass.
- This extraction provides a concrete next step after the project settings boundary.

## Verification

- `mix test test/symphony_elixir_web/admin/settings_check_test.exs`
- `mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `rg -n "configuration_missing_items|workflow_profile_targets|settings_check_|project_field_|workflow_field_" lib test`
- `mix exec_plans.check`

## Completion Deviations

Extracted settings check target derivation, match rules, messages, and CSS class decisions into `SymphonyElixirWeb.Admin.SettingsCheck`; `AdminLive` now delegates to that boundary.
