# 069 Run Phase Boundary Logs

## Goal

Make each issue run log explicit phase boundaries so operators can distinguish
workspace bootstrap failures from Codex startup, Codex streaming activity, and
Codex stall/retry behavior without inferring from nearby messages.

## Status

Completed.

## Background

Recent runtime logs interleaved `project_bootstrap` timeouts and Codex
notification history across retries for the same issue. This made it look like
Git clone and Codex prompt notifications were happening in the same attempt.
They are separate phases: `project_bootstrap` runs before Codex starts, while
Codex notifications only happen after `Codex session started`.

The runtime needs phase boundary logs and events that make this separation
obvious for every attempt.

## Scope

- Add clear phase boundary logs for local agent attempts:
  - workspace preparation starting;
  - project bootstrap/custom after-create hook phase;
  - before-run hook phase;
  - Codex session starting;
  - Codex session running/started;
  - Codex session completed or failed;
  - after-run hook phase;
  - retry scheduled/failure phase.
- Include issue id, issue identifier, worker host, attempt, and phase name in
  boundary logs where available.
- Persist phase boundary events through the existing persistence event path so
  run detail/event pages can show the phase timeline.
- Ensure a `project_bootstrap` timeout is logged and persisted as a workspace
  phase failure, not a Codex phase failure.
- Ensure Codex notification/session-history events only appear after Codex phase
  start.

## Out of Scope

- Redesigning the run detail page.
- Adding a new database schema.
- Changing retry policy.
- Changing workspace clone behavior.
- Changing Codex protocol parsing.

## Acceptance Criteria

- Logs contain explicit phase boundary messages using stable phase names.
- Workspace bootstrap timeout logs include `phase=workspace_bootstrap`.
- Codex session start logs include `phase=codex_starting` or
  `phase=codex_running`.
- Codex notification handling is not changed, but phase logs make it clear those
  notifications belong to a later phase.
- Persisted events include phase boundary events with phase, issue identifier,
  worker host, and attempt when available.
- Focused tests pass.
- `mise exec -- mix lint` passes.
- `mise exec -- mix test` passes.

## Test Cases

- Agent runner emits a phase event before workspace creation.
- Workspace hook timeout emits a phase failure event for `workspace_bootstrap`.
- A successful fake Codex run emits ordered phase events around Codex startup
  and completion.
- Orchestrator/session history behavior remains unchanged.

## Implementation Notes

- Prefer adding a small `RunPhase` helper or local functions rather than
  scattering ad hoc event maps.
- Use the existing `PersistenceProvider.module().record_event/1` API.
- The log line should be operator-readable and grep-friendly, for example:
  `Run phase phase=workspace_bootstrap status=started issue_identifier=CCR-3`.
- Keep phase names stable because they will likely be used by the run detail UI.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs` passed: 50 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/core_test.exs` passed: 59 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/core_test.exs` passed: 109 tests, 0 failures.
- `mise exec -- mix lint` passed.
- `mise exec -- mix test` passed: 288 tests, 0 failures, 2 skipped.

## Completion Deviations

- Phase events were implemented with the existing persistence event API using
  `event_type: "run.phase"` instead of adding a new helper module or schema.
- Workspace hook phase names are derived in `Workspace` so hook start,
  completion, failure, and timeout events use the same phase vocabulary as
  `AgentRunner`.
- Retry scheduling was left unchanged; the delivered boundary logs identify the
  failed phase before the existing retry logs.

## Dependencies

- Existing persistence event API.
- Existing workspace hook events from
  [064-bootstrap-noninteractive-streaming-diagnostics.md](../completed/064-bootstrap-noninteractive-streaming-diagnostics.md).

## Handoff Notes

This plan should make phase boundaries visible even when retries interleave for
the same Linear issue. It should not rely on dashboard session history alone,
because session history only exists after Codex updates are received.
