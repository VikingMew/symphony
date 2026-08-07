# 205 Workspace Source Preparation Test Split

## Goal

Split `workspace/source_preparation_test.exs` into focused source-strategy test files that reflect clone, worktree, local path, hook, and cleanup responsibilities.

## Status

Completed.

## Background

`test/symphony_elixir/workspace/source_preparation_test.exs` is roughly 1,000 lines. The production workspace code has accumulated several source strategies and safety checks, and the test file mirrors that breadth in one place.

This makes it harder to add focused changes to workspace lifecycle behavior without scanning unrelated setup.

## Scope

- Inventory test groups by source strategy and safety behavior.
- Move one source-strategy group into a dedicated test file first.
- Keep filesystem setup helpers explicit and local where possible.
- Preserve assertions around path containment, cleanup, and source preparation.
- Coordinate with completed plan 202 if workspace production boundaries are thinned.

## Out of Scope

- Changing workspace behavior.
- Changing configured source strategies.
- Implementing disk-space checks owned by completed plan 192.
- Rewriting all workspace tests in one pass.

## Acceptance Criteria

- `source_preparation_test.exs` loses at least one coherent source-strategy group.
- New file names match the source strategy or safety concern.
- Shared helpers remain small and do not obscure per-strategy setup.
- Existing workspace tests still pass.
- The split gives future workspace refactors an obvious test owner.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace/source_preparation_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace`
- `wc -l test/symphony_elixir/workspace/source_preparation_test.exs test/symphony_elixir/workspace/*.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 091 for worktree source strategy runtime.
- Completed plan 096 for workspace source root layout.
- Completed plan 145 for workspace hook execution boundary.
- Completed plan 146 for workspace remote operations boundary.
- Completed plan 202 for workspace lifecycle facade thinning.

## Handoff Notes

Split by source behavior, not by arbitrary line ranges. The resulting files should tell readers which workspace contract broke.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

