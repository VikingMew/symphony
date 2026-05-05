# Task 011: Worker Heartbeat, Lease Expiry, and Cancellation

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 010
**Created**: 2026-05-01

## Goal

Add heartbeat, lease renewal, offline detection, lease expiry, and cooperative cancellation support for worker-backed tasks.

## Background

Worker leases are only useful if the Panel can detect dead workers and recover stale work. Cancellation also needs a Panel-to-worker command path without requiring inbound network access to worker machines.

## Scope

- Add `POST /api/worker/v1/heartbeat`.
- Renew active leases from heartbeat payload.
- Update worker session `last_heartbeat_at` and worker `last_seen_at`.
- Mark workers/sessions offline after missed heartbeat threshold.
- Expire stale leases.
- Requeue or fail tasks according to retry policy.
- Add cancellation command delivery through heartbeat response.
- Persist heartbeat timeout, lease expiry, and cancellation events.

## Out of Scope

- Worker-side cancellation implementation.
- Result reporting endpoints.
- Dashboard controls for cancellation.
- Removing in-process cancellation behavior.

## Centralized Deployment Compatibility

Heartbeat and lease expiry apply only to worker-backed tasks. Centralized in-process runs should continue to use existing process supervision, stop, and retry behavior until explicitly migrated.

## Acceptance Criteria

- [ ] Heartbeat updates worker/session liveness.
- [ ] Heartbeat renews active leases.
- [ ] Missing heartbeat marks worker/session offline.
- [ ] Expired leases are detected and transitioned.
- [ ] Expired tasks are requeued or failed according to retry policy.
- [ ] Cancellation commands can be queued and returned to worker heartbeat.
- [ ] Existing centralized stop/retry behavior remains functional.

## Test Cases

- Heartbeat with no active leases.
- Heartbeat with active lease renewal.
- Heartbeat with unknown lease.
- Session marked offline after timeout.
- Lease expires after timeout.
- Expired lease requeues retryable task.
- Cancellation command appears in heartbeat response.
- Centralized run cancellation test remains unchanged.

## Implementation Notes

- Keep all timeout values configurable.
- Use server time for lease expiry decisions.
- Avoid relying on worker clocks.
- Consider a periodic reconciler process for stale sessions and leases.
- Persist enough events to debug why a task was requeued.

## Verification

- `mise exec -- mix test test/symphony_elixir/worker_heartbeat_test.exs`
- `mise exec -- mix test test/symphony_elixir/worker_lease_expiry_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added heartbeat API and lease renewal.
- Added stale session/lease expiry context function.
- Added cooperative cancellation through task status and heartbeat commands.
- Expiry reconciliation is exposed as a context function; wiring it to a periodic OTP reconciler remains follow-up work.

## Dependencies

- Task queue and lease API from Task 010.

## Handoff Notes

- Record default heartbeat interval and expiry thresholds.
- Record whether expiry is handled synchronously, by Oban-like job, or by OTP reconciler.
- Record final cancellation command payload.
