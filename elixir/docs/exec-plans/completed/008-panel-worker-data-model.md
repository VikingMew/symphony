# Task 008: Panel Worker Data Model

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 002, Task 004, Task 007
**Created**: 2026-05-01

## Goal

Add the Panel-side persistence model required for future external workers, without changing the current execution mode.

## Background

The Panel / Worker design requires durable worker identity, worker sessions, tasks, and leases. This phase prepares the database and domain context only. Symphony must continue to support centralized deployment where the Phoenix Panel performs in-process execution.

Design reference: [Panel / Worker 解耦设计](../../worker_panel_decoupling_design.zh-CN.md).

## Scope

- Add Ecto schemas and migrations for `workers`, `worker_sessions`, `worker_credentials` or credential metadata, `tasks`, and `task_leases`.
- Add indexes and uniqueness constraints needed for worker identity and active lease safety.
- Add context functions for creating/listing/updating workers, sessions, tasks, and leases.
- Add worker/task event helpers if current `events` schema needs typed support.
- Keep all new fields JSON-compatible for Rust worker protocol usage.

## Out of Scope

- Worker HTTP API.
- Rust worker implementation.
- Scheduler integration.
- Dashboard pages.
- Switching default execution to worker mode.

## Centralized Deployment Compatibility

The existing in-process execution path must remain the default after this task. New tables can exist unused in centralized deployments. No operator should need to configure workers to keep the current service running.

## Acceptance Criteria

- [ ] Database migration creates worker/task/lease tables.
- [ ] Context functions can create and update worker records.
- [ ] Context functions can create queued tasks without assigning them.
- [ ] Active lease uniqueness is enforced at the database or transaction layer.
- [ ] Existing tests for centralized execution still pass.
- [ ] No runtime path requires a worker to be registered.

## Test Cases

- Create a worker with labels and capabilities.
- Reuse or reject duplicate worker identity according to the chosen uniqueness rule.
- Create a worker session linked to a worker.
- Create a queued task linked to project/run/workflow version where applicable.
- Create one active lease for a task.
- Attempt to create two active leases for one task and assert failure.
- Verify existing in-process orchestration tests pass unchanged.

## Implementation Notes

- Prefer explicit schemas under `SymphonyElixir.Persistence`.
- Store labels/capabilities/payload as maps or arrays through Ecto JSON fields.
- Add indexes for `worker_id`, `session_id`, `task_id`, `status`, `expires_at`, and `project_id`.
- Keep credential values out of plain database fields; store only hashes or references.

## Verification

- `mise exec -- mix test test/symphony_elixir/worker_registry_test.exs`
- `mise exec -- mix test test/symphony_elixir/worker_task_lease_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Implemented `workers`, `worker_sessions`, `tasks`, and `task_leases`.
- Added `execution_mode` to runs so centralized and worker-backed runs can be distinguished.
- Credential handling is metadata/token-config based in this pass; full token rotation UI remains future work.

## Dependencies

- SQLite persistence from Task 002.
- Runtime state persistence from Task 004.

## Handoff Notes

- Record final table names and indexes.
- Record whether credential metadata is a separate table or part of `workers`.
- Record any fields intentionally deferred to later phases.
