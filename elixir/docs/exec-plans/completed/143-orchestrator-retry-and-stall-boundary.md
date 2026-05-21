# 143 - Orchestrator Retry And Stall Boundary

Status: Completed

## Problem

`SymphonyElixir.Orchestrator` still mixes retry scheduling, retry metadata shaping, stalled-run detection, retry timer ownership, and workspace cleanup decisions with normal dispatch flow.

The retry/stall code is a coherent behavior slice, but it is spread across helpers such as `schedule_issue_retry/4`, `handle_retry_issue/5`, `reconcile_stalled_running_issues/1`, `restart_stalled_issue/5`, retry delay calculation, retry metadata picking, and retry timer cancellation.

This makes retry semantics harder to review and increases the risk that normal dispatch changes accidentally alter retry behavior.

## Goal

Create a retry/stall boundary that owns retry attempt calculation, retry metadata normalization, stalled-entry detection, and retry timer bookkeeping inputs/outputs.

The GenServer should remain responsible for sending/receiving messages and mutating state.

## Plan

1. Inventory retry and stall helpers in `orchestrator.ex`.
2. Define a pure data contract for retry decisions, such as `{:retry, issue_id, attempt, delay_ms, metadata}` or `:no_retry`.
3. Extract retry delay, attempt normalization, retry metadata selection, and stale running-entry detection into `Orchestrator.RetryPolicy` or similar.
4. Keep actual `Process.send_after/3`, task termination, and workspace cleanup in the orchestrator process.
5. Add focused tests for retry attempts, stalled detection, failed lookup behavior, worker host preservation, and cleanup metadata.
6. Update orchestrator integration tests only where process behavior must be proven.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator/retry_policy_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs`
  - `107 tests, 0 failures`
  - Covers retry metadata normalization, backoff delay calculation, continuation delay, stale retry token handling, stalled-entry detection, and existing orchestrator retry/stall behavior.
- `rg -n "schedule_issue_retry|handle_retry_issue|reconcile_stalled|restart_stalled|retry_delay|retry_attempt|pick_retry|stall_decision|RetryPolicy" lib test/symphony_elixir/orchestrator test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs`
  - Confirms retry/stall calculations are centralized in `Orchestrator.RetryPolicy` while timers and state mutation remain in `Orchestrator`.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
