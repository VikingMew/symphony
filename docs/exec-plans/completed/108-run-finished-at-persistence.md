# 108 Run Finished At Persistence

## Goal

Fix persisted run records so completed, failed, stopped, or superseded agent runs no longer stay forever as `status = "running"` with `finished_at = nil` on the Runs page.

## Status

Completed.

## Background

The Runs page currently shows many historical attempts for the same issue as still running:

```text
Issue        Status   Attempt   Started                         Finished
CCR-5 Issue  running  2         2026-05-21T00:57:28.998053Z    n/a
CCR-5 Issue  running  1         2026-05-21T00:47:52.487504Z    n/a
CCR-5 Issue  running  0         2026-05-21T00:37:53.590423Z    n/a
...
```

This is wrong operationally. Each retry attempt should close the previous persisted run with a terminal status and `finished_at`. Otherwise users cannot tell which attempt is actually active, how long an attempt ran, or why it was retried.

The current central orchestrator path creates a `RunRecord` when dispatching an issue and attempts to update it from `persist_run_finished/3` on worker down or stop. The observed data means at least one of these paths is incomplete or unreliable:

- normal agent completion;
- domain failure and retry scheduling;
- crash/stall handling;
- forced stop/cancel;
- process restart with stale `running` rows from a previous runtime;
- async persistence update failing silently;
- runs created by worker-mode task transitions versus central-mode `AgentRunner`.

Worker-mode task events already update task/run terminal status through task event transitions. This plan focuses on making all central-mode run lifecycle exits persist terminal state reliably, and making stale startup state safe.

## Scope

- Audit every central-mode run lifecycle path that creates or terminates a run:
  - dispatch start;
  - normal agent completion;
  - agent domain failure;
  - process crash;
  - stall restart/backoff;
  - forced stop;
  - startup spawn failure if a run was created;
  - runtime shutdown/restart recovery for stale running rows.
- Ensure every terminal outcome updates the associated `RunRecord` with:
  - terminal `status`;
  - `finished_at`;
  - `failure_reason` where applicable.
- Ensure retry scheduling closes the failed attempt before the next attempt creates a new run.
- Avoid swallowing persistence failures silently in the critical path. At minimum, log a structured warning with run id, issue identifier, target status, and reason.
- Add a stale-run reconciliation step at startup or orchestrator initialization:
  - find persisted runs with `status = "running"` from a previous process with no corresponding in-memory running entry;
  - mark them as `failed` or `interrupted` with `finished_at`;
  - use an explicit failure reason such as `runtime restarted before run finished`.
- Keep worker-mode task event transition behavior intact.
- Update Runs and Run Detail pages only if they need clearer terminal status display; the core bug is persistence, not table formatting.
- Add regression tests using fake persistence or mocked persistence boundaries; do not require a real Linear or Codex run.

## Out of Scope

- Do not redesign the Runs page.
- Do not add historical session event querying here; that is plan 103.
- Do not change retry policy or retry delay behavior.
- Do not delete old bad run rows automatically beyond the defined stale-running reconciliation.
- Do not infer exact historical finish times for old rows; for reconciliation, use the reconciliation time as `finished_at`.
- Do not make issue-level run aggregation the primary fix.

## Acceptance Criteria

- A normally completed central-mode agent run persists `status = "completed"` and non-nil `finished_at`.
- A central-mode agent failure persists `status = "failed"`, non-nil `finished_at`, and a useful `failure_reason`.
- A stalled run that is restarted/backed off closes the previous run before scheduling or starting the next attempt.
- A forced stop persists `status = "stopped"` and non-nil `finished_at`.
- Startup reconciliation closes stale `running` runs from previous runtime state with a clear failure reason.
- The Runs page no longer shows multiple old attempts for the same issue as `running` unless they truly have active in-memory work.
- Worker-mode task completion/failure/cancellation still updates the associated run as before.
- Persistence update failures are visible in logs instead of silently disappearing.

## Test Cases

- Orchestrator central-mode normal completion creates a run and later updates it to `completed` with `finished_at`.
- Orchestrator central-mode domain failure creates a run and later updates it to `failed` with `finished_at` and `failure_reason`.
- Stall/retry path marks the current run terminal before a new retry attempt creates another run.
- Forced stop path marks the current run `stopped` with `finished_at`.
- Startup reconciliation marks stale `running` runs as `failed` or `interrupted` when no active in-memory entry exists.
- Worker task event tests still prove `task.completed`, `task.failed`, and `task.cancelled` update the run terminal fields.
- Web fake persistence test renders a run with a non-nil `finished_at` after terminal update.
- Regression test with multiple attempts for the same issue proves only the currently active attempt remains `running`.

## Implementation Notes

- Start in `SymphonyElixir.Orchestrator`:
  - `persist_run_started/3`;
  - `persist_run_finished/3`;
  - `persist_run_finished_async/3`;
  - worker down handling;
  - stall reconciliation/retry handling;
  - forced stop handling.
- Prefer making terminal run persistence explicit and synchronous enough that a fast retry cannot create the next run before the previous run is closed. If async persistence remains, it must be supervised/logged and tests must account for completion.
- Consider adding a small persistence API such as `finish_run(run_id, attrs)` so callers do not need to fetch and update the `RunRecord` manually.
- Add `Persistence.list_running_runs/0` or a filtered `list_runs(status: "running")` only if needed for startup reconciliation.
- Keep statuses consistent with existing `RunRecord` usage:
  - `running`;
  - `completed`;
  - `failed`;
  - `stopped`;
  - worker-mode statuses such as `queued` if already used.
- If introducing a new stale status such as `interrupted`, update badge styling and tests. If avoiding new status, use `failed` with `failure_reason = "runtime restarted before run finished"`.
- Do not rely on the LiveView table to mask bad data. The database row should be correct.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/core_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- `mise exec -- mix format --check-formatted`
- `git diff --check`

## Completion Deviations

Implemented with `SymphonyElixir.RunLifecycle` and synchronous central-mode terminal updates. Orchestrator startup now reconciles stale persisted `running` rows, and worker down paths close runs before retry scheduling proceeds. Persistence failures are logged by the lifecycle boundary.

## Dependencies

- Existing `RunRecord` persistence model.
- Existing central-mode `AgentRunner` orchestration.
- Existing worker-mode task transition code.
- Plan 103 is related but separate: it handles historical session event query/presentation, not run terminal persistence.

## Handoff Notes

Treat `finished_at = nil` as meaning "this run is genuinely active now," not "we forgot to close it." The fix should make the persisted Runs page trustworthy for debugging retries and long-running failures.
