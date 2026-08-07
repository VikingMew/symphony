# 058 Clean Workspace On Start

## Goal

Guarantee every new agent/workspace start uses a fresh issue workspace directory by deleting any existing issue directory before creating and bootstrapping it.

## Status

Completed.

## Background

The current workspace behavior intentionally reuses an existing issue directory. If the directory already exists, Symphony skips `after_create` / generated project bootstrap and preserves local changes, build output, dependency caches, and scratch files. That behavior makes retries and repeated starts vulnerable to stale state from previous attempts.

The desired contract is simpler: every start is a clean start. There is no compatibility switch and no reuse mode.

## Scope

- Change local workspace creation so an existing issue directory is removed before a new run starts.
- Change remote workspace preparation so an existing issue directory is removed before a new run starts.
- Ensure `after_create` / generated project bootstrap runs for every workspace start.
- Update tests that currently assert reuse/preservation to assert clean recreation.
- Update docs to state that issue workspaces are recreated on start and local progress must be committed/pushed or recorded elsewhere before retry.

## Out of Scope

- Adding a reuse/clean configuration switch.
- Preserving dependency caches across starts.
- Changing terminal cleanup behavior.
- Changing workspace root path validation.

## Acceptance Criteria

- [x] Calling `Workspace.create_for_issue/2` twice for the same issue deletes files left by the first call.
- [x] `after_create` or generated project bootstrap runs on the second call.
- [x] Remote worker workspace preparation removes an existing remote issue directory before recreating it.
- [x] Existing path safety checks still prevent deleting outside the configured workspace root.
- [x] Documentation describes clean-on-start behavior.
- [x] Relevant tests pass.
- [x] Full test suite and coverage remain at or above the project threshold.

## Test Cases

- Local existing issue directory with modified files is removed and recreated.
- Local existing non-directory path is still replaced safely.
- Hook/bootstrap execution counter increments on every start for the same issue.
- Remote preparation script includes unconditional removal/recreation of the issue workspace.
- `Workspace.remove/1` still rejects deleting the workspace root itself.

## Implementation Notes

- The current `ensure_workspace/2` returns `created? = false` for existing directories. The new behavior should always return `created? = true` after validation so the bootstrap path runs each start.
- Deletion must remain limited to the per-issue workspace path returned by `workspace_path_for_issue/2` after `validate_workspace_path/2`.
- For remote workers, keep using shell quoting through `remote_shell_assign/2`; do not interpolate raw paths directly.

## Verification

Passed:

- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- make all` progressed through setup, build, format check, lint, and coverage. Coverage ran 273 tests with 0 failures, 2 skipped, and 83.32% total coverage.

Known unrelated blocker:

- `mise exec -- make all` failed at the final Dialyzer step with existing repository warnings in modules such as `persistence.ex`, `orchestrator.ex`, `workflow.ex`, and `workflow_validator.ex`.

## Completion Deviations

`make all` is not fully green because Dialyzer currently reports existing project-wide warnings. The clean-workspace behavior itself is covered by focused tests and the full coverage test run.

## Dependencies

- Existing workspace path safety checks.
- Existing project bootstrap generated hook behavior.

## Handoff Notes

This plan intentionally removes workspace reuse semantics. Any future desire for warm caches should be modeled separately and must not make the active issue workspace dirty at run start.
