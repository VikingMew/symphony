# Task 009: Worker Registration and Handshake API

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 008
**Created**: 2026-05-01

## Goal

Expose the first Panel-side worker API endpoint so an external Rust worker can register, authenticate, negotiate protocol version, and receive a session.

## Background

Workers should initiate connections to the Panel. The Panel must not assume direct access to worker machines. This phase creates the handshake contract but does not assign work yet.

## Scope

- Add `POST /api/worker/v1/register`.
- Validate worker registration token.
- Validate `protocol_version`.
- Create or reuse stable worker identity.
- Create a new worker session per process start.
- Return `worker_id`, `session_id`, heartbeat interval, lease duration, server time, and accepted protocol version.
- Record registration success/failure events.
- Document request/response examples in API docs or the design doc.

## Out of Scope

- Task claim API.
- Heartbeat API.
- Result reporting API.
- Rust worker implementation.
- Dashboard token management UI.

## Centralized Deployment Compatibility

Worker registration must be optional. Centralized deployments without workers continue using in-process execution. Worker API authentication must not depend on dashboard auth being enabled.

## Acceptance Criteria

- [ ] Valid worker token can register a worker.
- [ ] Invalid token is rejected.
- [ ] Unsupported protocol version is rejected with a clear error.
- [ ] Re-registering the same worker identity creates a new session without duplicating the logical worker.
- [ ] Registration records worker metadata and session metadata.
- [ ] Existing centralized execution behavior remains unchanged.

## Test Cases

- Register with valid token.
- Register with missing token.
- Register with invalid token.
- Register with unsupported protocol version.
- Register the same worker twice and verify one worker plus two sessions.
- Register with malformed capability payload and verify validation error.
- Run existing controller/auth tests to ensure dashboard auth behavior is not affected.

## Implementation Notes

- Use a dedicated worker API pipeline rather than the browser/session auth pipeline.
- Avoid logging raw token values.
- Use plain JSON request/response shapes compatible with Rust clients.
- Add protocol headers such as `X-Symphony-Worker-Protocol` where useful, but keep registration payload self-contained.

## Verification

- `mise exec -- mix test test/symphony_elixir_web/worker_registration_api_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added `POST /api/worker/v1/register` with pre-shared token authentication.
- Registration creates or reuses stable worker identity and creates a new session.
- Full dashboard token creation/rotation was not included; token is configured by environment/app config.

## Dependencies

- Worker data model from Task 008.

## Handoff Notes

- Record the final token configuration mechanism.
- Record the first supported protocol version string.
- Record any API response shape changes back into the design doc.
