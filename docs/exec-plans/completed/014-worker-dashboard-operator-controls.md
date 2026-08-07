# Task 014: Worker Dashboard and Operator Controls

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 011, Task 012, Task 013
**Created**: 2026-05-01

## Goal

Expose worker, task, lease, and execution-mode state in the Phoenix dashboard without introducing a separate frontend project.

## Background

Once worker state is persisted, operators need to see what is online, what is leased, what is queued, and why work is stuck. Dashboard support is also needed to make centralized vs worker mode understandable.

## Scope

- Add workers list page.
- Add worker detail page with sessions and last heartbeat.
- Add task list filtered by status/project/worker.
- Add lease visibility for active, expired, and released leases.
- Add worker event timeline.
- Add cancel/requeue controls where server APIs exist.
- Show execution mode for project/run/task.
- Show clear empty states for centralized deployments with no workers.

## Out of Scope

- Complex analytics.
- Separate SPA/Node frontend.
- Raw log streaming UI.
- Full worker token rotation UI unless earlier phases expose the API.

## Centralized Deployment Compatibility

The dashboard must make centralized deployment a first-class state. If no workers exist, the UI should say the project is using centralized execution or that worker mode is not enabled, rather than showing an error.

## Acceptance Criteria

- [ ] Workers page renders no-worker centralized empty state.
- [ ] Workers page shows online/offline workers.
- [ ] Worker detail shows sessions, capabilities, last heartbeat, and active leases.
- [ ] Task list shows queued/running/expired/completed/cancelled tasks.
- [ ] Operator can request cancellation/requeue where supported.
- [ ] Run/project pages show execution mode.
- [ ] Dashboard pages remain protected by existing auth.

## Test Cases

- Render workers page with no workers.
- Render workers page with online worker.
- Render offline worker after missed heartbeat.
- Render worker detail with active lease.
- Render queued and expired tasks.
- Trigger cancel action and verify command/event is recorded.
- Verify unauthenticated user cannot access worker pages when auth is enabled.

## Implementation Notes

- Use Phoenix LiveView and existing admin/dashboard patterns.
- Keep pages operational and compact.
- Avoid adding a Node build requirement.
- Query persisted tables, not in-memory worker process state.

## Verification

- `mise exec -- mix test test/symphony_elixir_web/worker_dashboard_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added `/workers` dashboard page showing execution mode, workers, and tasks.
- Added basic task cancel/requeue controls.
- Rich worker detail pages, pagination, and full token management remain future UI refinements.

## Dependencies

- Heartbeat and cancellation from Task 011.
- Result/event reporting from Task 012.
- Execution mode from Task 013.

## Handoff Notes

- Record which controls are read-only in the first UI pass.
- Record any pagination/filtering deferred.
- Record dashboard states that need real worker data to refine.
