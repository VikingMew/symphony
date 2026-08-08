# 245 Settings single-direction dependencies; drop the forwarding wrapper

## Goal

Make Settings page modules depend one-way (pages -> shared leaf modules), let the LiveView owner
own save/refresh, and remove the pure-forwarding `SettingsLive` wrapper.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix xref graph --format cycles` — PASS: the Settings page/shell/state/
  workflow_state length-7 cycle is GONE; remaining cycles are only the documented
  keep-as-is boundaries (persistence length-6, config length-4, orchestrator length-3,
  Tracker length-2).
- `mise exec -- mix test` — 710 tests, 0 failures, 2 skipped (FULL SUITE GREEN)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (8 files: -1 deleted settings_live.ex, +1 new
  settings/components.ex, router + 6 LiveView/settings modules; net -102 lines)

## Completion Deviations

- `SettingsLive` (pure 24-line forwarding wrapper) DELETED; all six `/settings*` routes now
  mount `AdminLive` directly (router.ex). This was the plan's default decision — the wrapper
  owned no state or events.
- Shared settings components/UI hoisted into `settings/components.ex` (leaf module, no page
  dependencies); SettingsShell slimmed (95 lines removed), page modules reference the leaf.
- `workflow_state.ex` no longer calls `State.refresh()` after save/restore; refresh now happens
  at the LiveView owner (AdminLive / settings pages) — one-way dependency restored.
- Test baseline unchanged at 710 (no test count change; existing settings route suites cover the
  rewire, and they pass).

