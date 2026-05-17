# 094 Worktree Bootstrap Timeout And Stall Boundary

## Goal

Make worktree bootstrap obey `Settings / Workflow / Bootstrap / Initialize timeout ms` and prevent the Codex stall watchdog from restarting runs before Codex has actually started.

## Status

Completed.

## Background

Worktree source strategy added a generated bootstrap path that can auto-clone a cached base repository and then create per-issue worktrees. The clone/fetch/worktree commands are project initialization, so they should be controlled by `workspace.initialize_timeout_ms`.

The current failure mode is confusing:

- worktree clone can run slowly for minutes,
- the run remains in `workspace_bootstrap`,
- no Codex session exists yet, so no Codex activity can be emitted,
- the orchestrator's stall watchdog restarts the issue as `stalled without codex activity`.

That makes a slow clone look like an agent failure and can create repeated retries while the underlying bootstrap command is still the real bottleneck.

## Scope

- Apply `workspace.initialize_timeout_ms` to worktree bootstrap git commands:
  - initial cached repository clone,
  - fetch/prune,
  - stale worktree cleanup,
  - worktree add.
- Preserve the existing timeout diagnostic shape:
  - `{:workspace_hook_timeout, "project_bootstrap", timeout_ms, details}`,
  - details include elapsed time and recent output where available,
  - log summaries continue to point operators to `Settings / Workflow / Bootstrap / Initialize timeout ms`.
- Keep custom lifecycle hooks controlled by `hooks.timeout_ms`.
- Change the Codex stall watchdog so it only measures silence after a Codex activity timestamp exists.
- Add regression tests for worktree initialize timeout and pre-Codex stall behavior.

## Out of Scope

- Do not redesign retry policy.
- Do not add background clone progress UI.
- Do not change where worktree base repositories are stored.
- Do not change project settings ownership.
- Do not change agent success/error classification beyond this pre-Codex boundary.

## Acceptance Criteria

- [x] Slow worktree clone fails with a `project_bootstrap` timeout using `workspace.initialize_timeout_ms`.
- [x] Worktree bootstrap timeout summaries reference `Initialize timeout ms`.
- [x] Worktree git command failures still include command args, status, and sanitized output.
- [x] The orchestrator does not restart a run as "stalled without codex activity" before any Codex activity has been observed.
- [x] Existing stalled Codex-session behavior still retries when Codex activity becomes stale.
- [x] Tests cover both worktree timeout and pre-Codex stall boundary.

## Test Cases

- Configure worktree source strategy with a fake slow `git` executable and `initialize_timeout_ms: 50`.
- Call `Workspace.create_for_issue/1`.
- Assert the result is `{:error, {:workspace_hook_timeout, "project_bootstrap", 50, details}}`.
- Assert recent output contains the fake git progress line.
- Seed an orchestrator running entry with no `last_codex_timestamp` and an old `started_at`.
- Tick the orchestrator.
- Assert the worker is not killed and no retry is scheduled.
- Keep the existing stale Codex timestamp test passing.

## Implementation Notes

- Keep `System.cmd/3` as the simple no-timeout path for quick internal git checks and cleanup paths where no initialize timeout applies.
- Add a timeout-aware `run_git/3` that shells through the same local command port used by workspace hooks.
- Convert the internal `local_command` timeout marker back to `project_bootstrap` when the timed command belongs to worktree bootstrap.
- Quote git args before shell execution.
- Treat `last_codex_timestamp == nil` as "Codex has not started" for the stall watchdog.

## Verification

- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix format --check-formatted`
- `git diff --check`

## Completion Deviations

- None.

## Dependencies

- Completed plan 091 for worktree source strategy.
- Completed plan 092 for agent exit result classification and independent initialize timeout.

## Handoff Notes

`stalled without codex activity` should mean "Codex started and then stopped reporting activity." It must not be used for workspace preparation, because no Codex activity can exist before the workspace is ready.
