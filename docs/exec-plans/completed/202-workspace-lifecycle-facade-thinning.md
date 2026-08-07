# 202 Workspace Lifecycle Facade Thinning

## Goal

Thin `SymphonyElixir.Workspace` into a lifecycle facade by moving remaining source-preparation and cleanup decision details into focused boundaries.

## Status

Completed.

## Background

`lib/symphony_elixir/workspace.ex` is still over 1,100 lines after earlier source, hook, and cleanup work. Completed plan 192 owns the new disk-space spawn guard, so this plan should not implement disk checks.

The remaining smell is that workspace lifecycle coordination and detailed source-preparation/cleanup decisions still live too close together. That increases the cost of changing clone/worktree behavior.

## Scope

- Inventory public and private responsibilities still inside `Workspace`.
- Identify one separable lifecycle concern, preferably source-preparation decision assembly or cleanup eligibility plumbing.
- Move that concern into a focused module while keeping the public `Workspace` API stable.
- Preserve existing clone/worktree behavior and path containment checks.
- Add focused tests for the extracted boundary.

## Out of Scope

- Disk-space spawn guard behavior owned by completed plan 192.
- Changing source strategy semantics.
- Changing configured workspace layout.
- Deleting workspace cleanup policy safeguards.

## Acceptance Criteria

- `Workspace` delegates a coherent lifecycle subproblem to a named module.
- Existing public workspace functions remain stable for callers.
- Source preparation and cleanup tests still pass.
- Root-containment and destructive cleanup checks are not weakened.
- `Workspace` line count drops for a real ownership split.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace/source_preparation_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_cleanup_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `wc -l lib/symphony_elixir/workspace.ex lib/symphony_elixir/workspace/*.ex`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 091 for worktree source strategy runtime.
- Completed plan 096 for workspace source root layout.
- Completed plan 122 for workspace cleanup policy boundary.
- Completed plan 145 for workspace hook execution boundary.
- Completed plan 146 for workspace remote operations boundary.
- Completed plan 192 for disk-space spawn guard.

## Handoff Notes

Do not turn this into a broad rewrite. Pick one lifecycle concern with a crisp input/output contract and move it whole.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

