# Task 013: Scheduler and Orchestrator Worker Integration

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 010, Task 012
**Created**: 2026-05-01

## Goal

Integrate worker-backed task production into the existing Panel scheduler/orchestrator while keeping centralized in-process execution as a supported deployment mode.

## Background

Earlier phases create worker APIs and persistence, but the existing orchestrator still directly executes runs. This phase introduces an execution mode boundary so the Panel can either execute centrally or create worker tasks.

## Scope

- Add explicit execution mode configuration: `centralized` and `worker`.
- Keep `centralized` as the default until the Rust worker path is proven.
- When `worker` mode is enabled, tracker-discovered eligible issues create queued tasks.
- Bind tasks to project, run, workflow version, and issue.
- Ensure retry/backoff logic works for worker-backed tasks.
- Keep existing direct execution code path available and tested.
- Record execution mode in run/task metadata for debugging.

## Out of Scope

- Rust worker implementation.
- Dashboard worker controls.
- Removing direct local execution.
- Multi-worker fairness tuning beyond the initial scheduler rules.

## Centralized Deployment Compatibility

This task explicitly preserves centralized deployment. Operators must be able to run the Panel as a single Phoenix service with local execution, without registering any worker. Worker mode should be opt-in through config or project settings.

## Acceptance Criteria

- [ ] Execution mode is explicit and documented.
- [ ] `centralized` mode remains the default.
- [ ] Existing orchestrator behavior is preserved in `centralized` mode.
- [ ] `worker` mode creates queued tasks instead of direct execution.
- [ ] Run records show which execution mode was used.
- [ ] Retry/backoff behavior works in both modes.
- [ ] Tests cover both execution modes.

## Test Cases

- Default config runs in centralized mode.
- Centralized mode starts existing local execution path.
- Worker mode creates a queued task for eligible issue.
- Worker mode does not directly start local Codex execution.
- Retryable worker task respects backoff.
- Same project can be switched between modes without corrupting workflow versions.
- Existing orchestrator test suite passes in centralized mode.

## Implementation Notes

- Avoid mixing execution-mode branching deep inside unrelated code.
- Prefer a small execution dispatcher boundary.
- Treat worker-backed tasks as another execution backend, not a replacement for all orchestration state.
- Record mode in events such as `run.started` or `task.queued`.

## Verification

- `mise exec -- mix test test/symphony_elixir/orchestrator_execution_mode_test.exs`
- `mise exec -- mix test test/symphony_elixir/worker_scheduler_integration_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added explicit execution mode support with centralized as default.
- Worker mode queues persisted worker tasks instead of spawning local Codex execution.
- Centralized execution path remains unchanged for default deployments.

## Dependencies

- Task queue and lease API from Task 010.
- Worker result reporting from Task 012.

## Handoff Notes

- Record final config key for execution mode.
- Record whether mode is global, per project, or both.
- Record any centralized behavior intentionally left unchanged.
