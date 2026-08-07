# Task 012: Worker Result and Event Reporting API

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 010, Task 011
**Created**: 2026-05-01

## Goal

Allow workers to report task progress, run state, agent turn summaries, workspace metadata, logs/artifact metadata, and terminal outcomes to the Panel.

## Background

The Panel remains the source of truth for dashboard and audit history. Workers execute tasks, but the Panel decides which state transitions are accepted.

## Scope

- Add `POST /api/worker/v1/tasks/:task_id/events`.
- Accept progress events such as workspace, hook, codex, agent turn, completion, failure, and cancellation.
- Validate that the reporting worker owns the active lease.
- Update `tasks`, `runs`, `agent_turns`, `workspaces`, and `events` consistently.
- Reject late completion after lease expiry or record it without changing terminal state.
- Add bounded payload validation for logs and artifact metadata.

## Out of Scope

- Streaming raw logs.
- Large artifact upload/storage.
- Worker implementation.
- Dashboard event timeline UI.

## Centralized Deployment Compatibility

Centralized in-process execution should continue writing run/events directly through existing server contexts. Worker reporting adds a second ingestion path and must not force centralized runs to simulate worker events.

## Acceptance Criteria

- [ ] Worker can report valid progress event while holding active lease.
- [ ] Worker can complete a task while holding active lease.
- [ ] Worker can fail or cancel a task while holding active lease.
- [ ] Reports from non-owner workers are rejected.
- [ ] Late completion does not overwrite current terminal state.
- [ ] Events are visible through existing event persistence queries.
- [ ] Centralized execution event persistence remains compatible.

## Test Cases

- Report `task.accepted`.
- Report workspace ready metadata.
- Report codex turn summary.
- Complete task successfully.
- Fail task with reason.
- Cancel task with reason.
- Reject event from wrong worker.
- Reject event after lease expiry.
- Verify centralized run events still render in existing tests.

## Implementation Notes

- Use a server-side state machine or explicit transition guards.
- Keep event payloads JSON-compatible and versioned.
- Cap payload size for log snippets.
- Store large logs/artifacts externally later; first version should store metadata only.

## Verification

- `mise exec -- mix test test/symphony_elixir_web/worker_event_reporting_api_test.exs`
- `mise exec -- mix test test/symphony_elixir/worker_state_transition_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added worker task event reporting API.
- Task terminal events now update task, run, event history, and release active leases.
- Large log/artifact storage remains metadata-only/future work.

## Dependencies

- Task queue and lease API from Task 010.
- Heartbeat and lease expiry from Task 011.

## Handoff Notes

- Record accepted event names.
- Record terminal state transition rules.
- Record payload size limits and deferred log/artifact handling.
