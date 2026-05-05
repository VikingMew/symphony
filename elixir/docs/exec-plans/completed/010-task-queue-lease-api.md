# Task 010: Task Queue and Lease API

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 008, Task 009
**Created**: 2026-05-01

## Goal

Allow authenticated workers to claim queued tasks through a lease-based API while preserving database-level safety against duplicate assignment.

## Background

Workers must not receive work by direct Panel process messages. The Panel should persist tasks, then grant time-bounded leases through an HTTP/JSON contract.

## Scope

- Add server-side functions to enqueue tasks.
- Add `POST /api/worker/v1/tasks/claim`.
- Match tasks against worker labels/capabilities.
- Respect worker available slots.
- Create active leases transactionally.
- Return task payload, lease id, expiry, run id, workflow version id, and execution metadata.
- Return no-task response with `poll_after_seconds`.
- Add idempotency behavior for duplicate claim attempts where practical.

## Out of Scope

- Heartbeat renewal.
- Lease expiry sweeper.
- Result reporting.
- Scheduler integration from tracker polling.
- Replacing centralized execution.

## Centralized Deployment Compatibility

This phase adds an alternative task claim path but must not require all runs to become queued worker tasks. Centralized in-process runs remain valid and should not need a worker lease.

## Acceptance Criteria

- [ ] Worker can claim a queued task matching its capabilities.
- [ ] Worker receives no-task response when nothing matches.
- [ ] Two workers cannot hold active leases for the same task.
- [ ] Capability mismatch prevents assignment.
- [ ] Claim API requires worker authentication/session.
- [ ] Existing in-process run tests continue to pass.

## Test Cases

- Claim matching task.
- Claim with missing required label.
- Claim with no available slots.
- Race two workers for one queued task and assert only one lease.
- Claim when queue is empty.
- Claim with invalid session.
- Verify centralized execution path does not create task leases unless explicitly configured.

## Implementation Notes

- Use database transactions for claim and lease creation.
- Prefer explicit task statuses: `queued`, `leased`, `running`, `completed`, `failed`, `cancelled`, `expired`.
- Keep task payload versioned.
- Do not put secret values directly in task payload unless the design explicitly permits it.

## Verification

- `mise exec -- mix test test/symphony_elixir/worker_task_lease_test.exs`
- `mise exec -- mix test test/symphony_elixir_web/worker_task_claim_api_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added task enqueueing and `POST /api/worker/v1/tasks/claim`.
- Claiming uses capability matching and an active lease uniqueness constraint.
- Idempotency keys are not yet a separate API concept; duplicate assignment is prevented by transactional status update and unique active lease.

## Dependencies

- Worker data model from Task 008.
- Worker registration API from Task 009.

## Handoff Notes

- Record final task status names.
- Record transaction strategy used to prevent duplicate active leases.
- Record any deferred idempotency behavior.
