# 245 Settings single-direction dependencies; drop the forwarding wrapper

## Goal

Make Settings page modules depend one-way (pages -> shared leaf modules), let the LiveView owner
own save/refresh, and remove the pure-forwarding `SettingsLive` wrapper.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md M5. After plan 236's split, `SettingsShell` renders five page modules
while pages `import` SettingsShell components (settings_shell.ex:6-9, 202-206;
settings/agents.ex:6-11; settings/workflow.ex:6-14); `State` calls `WorkflowState`, which calls
`State.refresh` after save (state.ex:17-25, 45; workflow_state.ex:15-17, 34-58, 95-122).
xref reports a length-7 export/runtime cycle. Meanwhile `SettingsLive` (settings_live.ex:1-23)
forwards all four callbacks to `AdminLive` — a wrapper with no owned state or events. Violates
Linus "remove complexity" (single-implementation forwarding layer, two-way deps) and Carmack
"hard to make simple is still worth it".

## Scope

- Hoist shared components/navigation into a leaf module with no page dependencies.
- `WorkflowState` returns save results; the LiveView owner calls refresh one-way.
- Delete the pure-forwarding `SettingsLive` and route `/settings*` directly to `AdminLive`
  (or keep it only if state/events are fully moved into it this plan — otherwise delete).
- Keep the dependency change single-direction; do NOT rewrite HEEx.

## Out of Scope

- Rewriting settings pages' markup or behavior.
- Further splitting of Settings modules.

## Acceptance Criteria

- xref cycle for the Settings page/shell/state/workflow_state group is gone (or reduced to
  one-directional edges).
- All `/settings*` routes behave identically (existing suites green).

## Test Cases

- Existing settings route tests (web_fake_persistence_test, settings_import_fake_persistence_test,
  observability_fake_persistence_test) green unchanged.
- xref cycle check.

## Implementation Notes

Delete-then-route is the lowest-risk first step (no new abstraction); hoisting components is
step two; flipping the save/refresh direction is step three — each step independently testable.

## Dependencies

- Plan 236 (split, complete) created this shape.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

