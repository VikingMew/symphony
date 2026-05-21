# 144 - Orchestrator Persistence Event Boundary

Status: Completed

## Problem

`SymphonyElixir.Orchestrator` still builds persistence records and event payloads directly for polled issues, run starts, queued worker tasks, run finishes, workspace updates, Codex updates, and generic events.

This is separate from scheduling. The process should decide when an event happened; a persistence/event boundary should decide how to shape the payload.

The current private helpers near `persist_polled_issues/1`, `persist_run_started/3`, `persist_worker_task_queued/3`, `persist_run_finished/3`, `persist_workspace_update/1`, and `persist_event/4` make payload shapes hard to test without full orchestrator flows.

## Goal

Extract event/persistence payload shaping out of `Orchestrator`.

The orchestrator should call a focused boundary with domain data and receive either persistence commands or already-shaped attributes for the persistence provider.

## Plan

1. Inventory all orchestrator persistence helpers and payload shapes.
2. Introduce a module such as `SymphonyElixir.Orchestrator.Events`.
3. Move pure payload construction and issue/run snapshot shaping into the new module.
4. Keep calls to `PersistenceProvider.module()` either in the orchestrator or behind a thin persistence adapter, but do not hide side effects inside broad helpers.
5. Add focused tests for every event type and failure payload currently emitted by the orchestrator.
6. Preserve existing event names and payload keys unless a separate behavior plan changes them.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator/events_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
  - `96 tests, 0 failures`
  - Covers issue snapshots, run/task attrs, run/task/workspace event payloads, and existing persistence-backed run-history rendering.
- `rg -n "persist_polled_issues|persist_run_started|persist_worker_task_queued|persist_run_finished|persist_workspace_update|persist_event|issue_snapshot" lib test`
  - Confirms payload shaping lives in `Orchestrator.Events`; `Orchestrator` retains persistence calls and process-side timing.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
