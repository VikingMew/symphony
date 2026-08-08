# 242 Force Stop partial-failure honesty

## Goal

Stop reporting `cancelled_tasks: 0` when task cancellation actually failed; expose partial failure
with typed results.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 710 tests, 1 failure (full suite). The single failure is the KNOWN
  flaky OrchestratorStatusTest timeout-type race (documented in the plan baseline; a re-run of the
  file passes: 45 tests, 0 failures). Not related to this plan (touches only the force_stop
  cancellation path).
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (orchestrator.ex + test/support/fake_persistence.exs
  + orchestrator_status_test.exs)

## Completion Deviations

- `cancel_active_worker_tasks/0` now returns `%{cancelled: n, failed: [...], status: :ok | :partial | :error}`:
  each `cancel_task/2` error/raised-exception/unexpected-result is captured per task id with an
  inspected reason; the list_tasks read is wrapped in plan-239's `PersistenceProvider.read/1`.
  Status logic: no failures -> :ok; all failed -> :error; mixed -> :partial.
- `force_stop_all` reply and the `orchestrator.force_stop_all` event payload now carry the typed
  `cancelled_tasks` map — "0" no longer means both "nothing to cancel" and "cancel failed".
- FakePersistence gained `put_cancel_task_errors/1` injection; three new tests cover success /
  partial / all-failed scenarios including the persisted event payload. Test baseline 706 -> 710
  (+4).

