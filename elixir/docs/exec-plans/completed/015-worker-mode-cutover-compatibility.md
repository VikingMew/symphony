# Task 015: Worker Mode Cutover and Compatibility

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 013, Task 014
**Created**: 2026-05-01

## Goal

Define and implement the controlled transition from centralized execution to worker-backed execution while continuing to support centralized deployments.

## Background

Symphony should not immediately become worker-only. Some users will run a single local Phoenix service for development or small deployments. Worker mode should become available and eventually preferred for stronger isolation, but centralized mode remains an explicitly supported mode.

## Scope

- Document deployment modes: `centralized`, `worker`, and optional `hybrid` if supported.
- Keep centralized mode available after worker mode ships.
- Add configuration validation for execution mode.
- Add migration documentation for moving a project to worker mode.
- Add compatibility tests for centralized mode.
- Add operational checks that warn when worker mode has no online workers.
- Add rollback guidance from worker mode to centralized mode.

## Out of Scope

- Rust worker implementation.
- Removing centralized execution.
- Distributed database or multi-Panel coordination.
- Advanced autoscaling.

## Centralized Deployment Compatibility

Centralized deployment remains supported after this task. The project should not require workers unless a project or global config explicitly selects worker mode. The dashboard and docs should describe centralized mode as supported, not deprecated, unless a future decision changes that.

## Acceptance Criteria

- [ ] Deployment modes are documented.
- [ ] Centralized mode remains available and tested.
- [ ] Worker mode can be enabled explicitly.
- [ ] Worker mode warns or blocks execution when no suitable worker is online.
- [ ] Operators can move a project back to centralized mode.
- [ ] README/user guide references both deployment modes.
- [ ] No existing centralized install is broken by default config.

## Test Cases

- Fresh install starts in centralized mode.
- Project explicitly set to worker mode queues tasks.
- Worker mode with no online workers shows actionable warning.
- Switching worker mode back to centralized mode stops new worker task creation.
- Existing user guide commands still work for centralized mode.
- Config validation rejects unknown execution mode.

## Implementation Notes

- Treat this as compatibility hardening, not a removal task.
- Make mode changes auditable events.
- Prefer per-project mode with a global default if configuration model supports it.
- Keep docs aligned with actual default behavior.

## Verification

- `mise exec -- mix test test/symphony_elixir/execution_mode_compatibility_test.exs`
- `mise exec -- mix test`
- Manual centralized startup using documented user guide commands.
- Manual worker-mode startup with fake or real worker where available.

## Completion Deviations

- Documented centralized as the default mode in README and user guide.
- Added `SYMPHONY_EXECUTION_MODE` support.
- Worker-backed execution is opt-in; centralized deployments continue to work without workers.

## Dependencies

- Scheduler/orchestrator integration from Task 013.
- Dashboard visibility from Task 014.

## Handoff Notes

- Record final supported deployment modes.
- Record default mode.
- Record any planned future deprecation policy if it changes.
