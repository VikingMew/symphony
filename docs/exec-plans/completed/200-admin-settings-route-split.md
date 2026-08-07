# 200 Admin Settings Route Split

## Goal

Move the settings/import route family out of `AdminLive` into a dedicated LiveView boundary while preserving existing URLs and behavior.

## Status

Completed.

## Background

Completed plan 182 split the workers route family out of `AdminLive`, but explicitly left settings, runs, and events for later. `lib/symphony_elixir_web/live/admin_live.ex` is still roughly 2,000 lines.

Completed plan 194 already owns runs pagination, so this plan should avoid the runs list and focus on the settings/import surface.

## Scope

- Inventory settings/import `live_action` branches still handled by `AdminLive`.
- Move the settings/import route family into a dedicated LiveView module.
- Preserve existing route paths and user-visible behavior.
- Reuse existing settings presenters/components instead of copying render logic.
- Move or add route tests that exercise the new LiveView directly.

## Out of Scope

- Runs list pagination or run detail behavior.
- Events page extraction.
- Redesigning settings UI.
- Changing persistence or import semantics.

## Acceptance Criteria

- Settings/import routes no longer render through `AdminLive`.
- URLs remain stable unless a deliberate route migration is documented.
- Shared helpers are extracted only when needed by both route families.
- Existing settings fake-persistence tests still cover settings behavior.
- `AdminLive` line count drops because a route family moved out.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir_web/live/settings_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `rg -n "settings|import|live_action" lib/symphony_elixir_web/live/admin_live.ex lib/symphony_elixir_web/live`
- `wc -l lib/symphony_elixir_web/live/admin_live.ex`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 165 for AdminLive settings check boundary.
- Completed plan 180 for settings fake persistence test split.
- Completed plan 182 for the first AdminLive route split.
- Completed plan 194 for runs page pagination, which this plan should not overlap.

## Handoff Notes

The win is ownership, not just fewer lines. Settings/import should become a page boundary with its own mount/handle/render lifecycle.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

