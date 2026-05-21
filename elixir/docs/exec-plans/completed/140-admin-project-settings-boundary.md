# 140 - Admin Project Settings Boundary

Status: Completed

## Problem

`AdminLive` remains a very large LiveView and still owns project settings behavior that is not inherently LiveView-specific.

Even after workflow settings package extraction, the module still contains:

- project settings save event handling,
- project form attribute construction,
- project change detection,
- repository/worktree preview logic,
- configuration checklist generation,
- Linear token/project status display decisions,
- project/team value formatting helpers,
- a large HEEx settings surface mixed with unrelated admin concerns.

This keeps domain logic embedded in a large UI module and makes changes riskier than necessary. The smell is not line count alone; it is that project settings parsing, validation, preview, and display derivation are hard to test without going through the full LiveView.

## Goal

Extract the project settings boundary from `AdminLive` so the LiveView coordinates events and rendering while a focused module owns settings state, derived preview data, and checklist decisions.

The end state should make project settings behavior testable without mounting the full admin page.

## Plan

1. Inventory all `AdminLive` functions that read or derive project settings state, including save handling, attrs, change detection, preview, checklist, and value helpers.
2. Define a focused module boundary such as `Admin.ProjectSettings` or `ProjectSettingsForm`.
3. Move pure derivation into that boundary first:
   - attrs from params,
   - changed-field detection,
   - repository/worktree preview,
   - configuration checklist items,
   - Linear project/team display values.
4. Keep LiveView event handling thin by delegating parsing and derived assigns to the new boundary.
5. Split HEEx rendering only where it improves locality without creating a second state owner.
6. Add focused tests for the extracted pure module and retain a small LiveView integration test for the save path.
7. Recheck `AdminLive` size and remaining private helpers to identify the next atomic extraction, if any.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir_web/admin/project_settings_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
  - `48 tests, 0 failures`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs`
  - `4 tests, 0 failures`
- `mise exec -- mix compile --warnings-as-errors`
- `rg -n "project_attrs|project_changed\\?|workspace_repository_preview|configuration_missing_items|save_project_settings|project_team_names|project_value" lib/symphony_elixir_web/live/admin_live.ex lib/symphony_elixir_web/admin/project_settings.ex lib test`
  - Project settings attrs, change detection, previews, checklist derivation, project values, and team display now live in `SymphonyElixirWeb.Admin.ProjectSettings`.
  - `AdminLive` keeps `save_project_settings` event orchestration and persistence calls.
- `wc -l lib/symphony_elixir_web/live/admin_live.ex`
  - `2341`
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
