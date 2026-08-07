# 063 Listening Control And Force Stop Agents

## Goal

Add explicit operator controls for starting/stopping Linear listening, make listening disabled by default on service startup, and provide a force-stop-all-agents button that cancels active Symphony work and rolls back Symphony-owned Linear state transitions.

## Status

Completed.

## Background

Today Symphony can start polling/listening for candidate Linear issues as soon as the runtime is configured. That is risky for an operator workflow where configuration may have just changed or where the service is started only to inspect dashboard state.

Operators need a deliberate "start listening" action. They also need an emergency stop that stops all active agents and returns Linear tasks to the last human-owned or pre-run state when Symphony has already advanced them, for example:

- `Ready -> In Progress` performed by Symphony after Codex session startup;
- `Ready to Merge -> Merging` performed by a merge flow;
- future backend-owned startup transitions.

The rollback must be careful. It should not blindly overwrite Linear when a human or Codex has moved the issue after the run started.

## Scope

- Introduce a runtime listening state controlled by the dashboard/API:
  - default state on process startup is `not_listening`;
  - when `not_listening`, Symphony does not poll Linear for new candidate issues and does not enqueue new worker tasks;
  - already-running agents are not started by default when service boots.
- Add dashboard controls:
  - "Start listening";
  - "Stop listening";
  - "Force stop all agents".
- Expose the listening state in dashboard status and JSON API state.
- Persist or record listening state changes as events. The default after process restart remains off unless a later explicit plan adds persistent auto-start.
- Define a force-stop path that:
  - stops polling/listening immediately;
  - marks all active local agent tasks for cancellation;
  - cancels or requeues leased worker tasks as appropriate;
  - terminates active Codex sessions/processes through existing supervision boundaries;
  - records a run/session event for each forced stop;
  - attempts Linear rollback for Symphony-owned transitions.
- Track per-run Linear state provenance:
  - issue state at claim/start;
  - every Symphony-owned state transition requested by backend code;
  - actor/source for the transition;
  - timestamp and target state.
- Roll back only when safe:
  - fetch current Linear state before rollback;
  - if current state equals a Symphony-owned target from this run, move it back to the corresponding previous state;
  - if current state has changed to something else, do not overwrite; add a comment/event explaining rollback skipped because Linear changed externally;
  - if rollback target no longer exists or is not allowed by workflow policy, do not force it; record a clear failure.
- Add a workflow-level rollback policy or derived mapping for backend-owned transitions. Initial required mappings:
  - `In Progress -> Ready` for a run that started from `Ready` and was auto-started by Symphony;
  - `Merging -> Ready to Merge` for a merge run that was auto-started by Symphony when that flow exists.
- Keep "Stop listening" distinct from "Force stop all agents":
  - stop listening prevents new work;
  - force stop cancels current work and attempts rollback.

## Out of Scope

- Persisting "listening enabled" across process restarts.
- Automatically resuming listening after deploy.
- Reverting git branches, deleting remote branches, or closing PRs.
- Rolling back Codex-authored task content, comments, or descriptions.
- Overwriting Linear states that humans changed after Symphony started.
- Guaranteeing rollback if Linear API credentials are missing or workflow states are absent.
- Building a full incident-management workflow.

## Acceptance Criteria

- [x] Starting Symphony with a valid workflow leaves Linear listening disabled by default.
- [x] While listening is disabled, scheduled polling does not fetch Linear candidate issues and no new agent run starts.
- [x] Dashboard and JSON state clearly show listening disabled/enabled.
- [x] Clicking "Start listening" enables polling and candidate dispatch.
- [x] Clicking "Stop listening" disables future polling/dispatch without killing already-running agents.
- [x] Clicking "Force stop all agents" disables listening and requests cancellation for every active agent/task.
- [x] Local active Codex sessions are stopped through existing app-server/session cleanup paths.
- [x] Worker-backed queued/leased/running tasks are cancelled or marked for cancellation consistently.
- [x] Symphony records the pre-run Linear state and backend-owned state transitions needed for rollback.
- [x] Force stop rolls back a task from `In Progress` to `Ready` only when this run moved it from `Ready` to `In Progress` and Linear still currently reports `In Progress`.
- [x] Force stop skips rollback, without overwriting, when Linear current state no longer matches the Symphony-owned target state.
- [x] Rollback failures are visible in events/session history and dashboard feedback.
- [x] Tests cover default-off listening, start/stop controls, no-poll behavior, force-stop cancellation, successful rollback, skipped rollback, and rollback failure.

## Test Cases

- Start orchestrator with valid config; assert snapshot shows `listening?: false` and polling does not call `Tracker.fetch_issues_by_states/1`.
- Trigger start listening; assert the next refresh can fetch candidate issues.
- Trigger stop listening with no active agents; assert state flips off and no cancellation occurs.
- Trigger stop listening with active agents; assert agents continue unless force stop is requested.
- Trigger force stop with active local agent; assert cancellation/session-stop path is called and a forced-stop event is recorded.
- Trigger force stop with worker tasks; assert queued tasks are cancelled and leased/running tasks are marked cancellation requested.
- Simulate a run that moved `Ready -> In Progress`; force stop while Linear still says `In Progress`; assert `Tracker.update_issue_state(issue_id, "Ready")` is called.
- Simulate a run that moved `Ready -> In Progress`; force stop after Linear says `Needs Implementation Review`; assert no rollback update is called and a skipped rollback event is recorded.
- Simulate rollback API failure; assert the run remains stopped and the rollback failure is visible.

## Implementation Notes

- Prefer modeling listening as explicit orchestrator state rather than overloading polling interval or active states.
- The default should be off in both file workflow mode and dashboard-first database workflow mode.
- Consider adding `Orchestrator.start_listening/0`, `Orchestrator.stop_listening/0`, and `Orchestrator.force_stop_all/1` public functions, then wiring LiveView/API buttons to those functions.
- Use existing cancellation mechanisms where present; do not kill processes with unstructured exits if a supervised stop/cancel path exists.
- Store transition provenance close to run/session state. A minimal structure can be:
  - `issue_id`;
  - `issue_identifier`;
  - `run_id`;
  - `from_state`;
  - `to_state`;
  - `source: :symphony_backend`;
  - `reason`;
  - `occurred_at`;
  - `rollback_to_state`.
- The `Ready -> In Progress` transition added by plan 061 must emit provenance.
- Rollback policy should be explicit enough that future backend-owned transitions can opt in. Avoid deriving rollback from arbitrary `allowed_transitions` alone.
- Force-stop UI must require confirmation because it can change Linear state.
- All rollback comments/events must avoid leaking API tokens, command env, or raw authorization headers.

## Verification

- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs` passed.
- `mise exec -- mix test` passed with 280 tests, 0 failures, 2 skipped.
- `mise exec -- mix lint` passed.
- `git diff --check` passed.

## Completion Deviations

Delivered rollback provenance for Symphony-owned backend transitions, starting with the `Ready -> In Progress` transition from plan 061. Force stop uses the existing local task termination path and cancels active worker tasks through the persistence boundary. Rollback comments to Linear were not added in this slice; rollback outcomes are recorded as Symphony events and returned in dashboard feedback.

## Dependencies

- Plan 054 running session state history.
- Plan 057 required project repository URL.
- Plan 061 Ready to In Progress on Codex start.
- Existing restricted Linear state update boundary.
- Existing worker task cancellation/requeue controls.

## Handoff Notes

The key safety rule is: force stop may only roll back states that Symphony itself moved during the current run and that Linear still reports as unchanged since that move. If Linear has advanced or been edited externally, Symphony should stop its own work and leave Linear state alone, with a visible event/comment explaining why rollback was skipped.
