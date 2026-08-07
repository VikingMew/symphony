# 203 Orchestrator Status Test Integration Split

## Goal

Split `orchestrator_status_test.exs` into smaller integration slices that match runtime responsibilities and reduce accidental coupling.

## Status

Completed.

## Background

Completed plan 171 split some orchestrator status ownership, but `test/symphony_elixir/orchestrator_status_test.exs` is still over 2,000 lines. A single file of that size encourages unrelated behaviors to share setup and makes failures harder to localize.

The production orchestrator is also large, so the tests should enforce clearer responsibility boundaries rather than mirror the large module shape.

## Scope

- Inventory test groups inside `orchestrator_status_test.exs`.
- Move one coherent group at a time into focused files, such as runtime summary, session history, active runs, blocked states, or operator controls.
- Keep shared setup in test support only when it is genuinely shared.
- Avoid changing assertions except where names/locations require mechanical updates.
- Preserve integration coverage while improving failure locality.

## Out of Scope

- Changing orchestrator behavior.
- Replacing integration tests with only unit tests.
- Rewriting the fake persistence layer.
- Operator-run model changes owned by completed plan 193.

## Acceptance Criteria

- No new test file becomes another large catch-all.
- `orchestrator_status_test.exs` loses at least one coherent behavior group.
- Shared helpers are named by domain behavior, not by the old file.
- Test count and behavioral assertions are preserved.
- Failures identify the relevant responsibility without opening a 2,000-line file.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator`
- `wc -l test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/orchestrator/*.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 171 for orchestrator status test ownership split.
- Completed plan 193 for operator runs.
- Completed plan 201 for session-history boundary, if implemented first.

## Handoff Notes

The goal is better test ownership. Avoid broad fixture churn and keep assertions stable unless the production contract intentionally changes.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

