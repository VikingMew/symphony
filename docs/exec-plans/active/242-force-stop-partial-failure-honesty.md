# 242 Force Stop partial-failure honesty

## Goal

Stop reporting `cancelled_tasks: 0` when task cancellation actually failed; expose partial failure
with typed results.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md M2. `cancel_active_worker_tasks/0` (orchestrator.ex:1784-1804, 2265-2276)
ignores each `cancel_task/2` error and catch-all-rescues list/query exceptions into `0`;
`force_stop_all` returns that value as a success result and event payload. `0` means BOTH "no
active tasks" AND "DB/cancel failed" — an operator cannot tell them apart. Violates "Explicit
errors over silent tolerance" and Carmack's dual-meaning prohibition.

## Scope

- `cancel_active_worker_tasks/0` returns a typed result:
  `%{cancelled: n, failed: [...], status: :ok | :partial | :error}` (or equivalent tuple),
  recording task id + reason for each failure.
- `force_stop_all` reply/event payload carries the typed result; API/UI shows partial failure.
- Local already-stopped processes need no rollback; keep partial-success semantics (no fake
  transactionality).

## Out of Scope

- Redesigning the cancel flow or retry policy.
- Rolling back already-completed stops.

## Acceptance Criteria

- Stubbed cancel failure -> `status: :partial`/`:error` with a non-empty `failed` list; the reply
  and the persisted event both reflect it.
- No active tasks -> `cancelled: 0, failed: [], status: :ok` (still distinguishable).

## Test Cases

- Cancel-success, cancel-partial, cancel-all-failed, and empty-cancel scenarios.
- Existing force_stop_all tests updated for the typed payload.

## Implementation Notes

Thread the typed result through `force_stop_all`'s reply and the `run.force_stopped` event payload
without changing stop semantics.

## Dependencies

- None.

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

