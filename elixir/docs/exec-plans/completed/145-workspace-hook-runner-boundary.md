# 145 - Workspace Hook Runner Boundary

Status: Completed

## Problem

`SymphonyElixir.Workspace` still owns lifecycle hook execution, local/remote command invocation, timeout handling, recent-output buffering, progress emission, hook event persistence, and hook result normalization.

Source preparation and cleanup policy have been separated, but hook execution remains a large responsibility inside the workspace module. This keeps workspace path creation coupled to shell execution details and event payload formatting.

## Goal

Extract hook execution into a focused boundary such as `SymphonyElixir.Workspace.HookRunner`.

`Workspace` should decide which hook to run and when. The hook runner should execute commands, stream output, apply timeouts, sanitize recent output, and return normalized results.

## Plan

1. Inventory hook-related helpers in `workspace.ex`, including project bootstrap, after-create, before-run, after-run, and before-remove.
2. Define a hook runner input struct/map containing command, workspace, issue context, worker host, timeout, and progress callback.
3. Move local hook process execution, remote hook execution, timeout handling, recent output buffering, and result normalization into the new boundary.
4. Keep `Workspace` responsible for workspace lifecycle order and cleanup/source preparation decisions.
5. Add direct tests for successful hooks, failed hooks, timeout diagnostics, remote command shape, output truncation, and progress callback emission.
6. Preserve existing phase names and persisted event payloads unless intentionally covered by tests.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace/hook_runner_test.exs test/symphony_elixir/workspace_and_config_test.exs`
  - `63 tests, 0 failures`
  - Covers local hook success, output callback emission, timeout diagnostics, recent-output bounding, and existing workspace hook lifecycle behavior.
- `rg -n "run_hook|run_project_bootstrap|run_optional_hook|receive_hook_port|persist_hook|phase_for_hook|workspace_hook_timeout" lib test`
  - Confirms local port execution and timeout buffering now live in `Workspace.HookRunner`; `Workspace` still owns hook ordering and event persistence.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

Remote hook command execution remains in `Workspace` because active plan 146 owns the remote command boundary. This plan extracted local hook execution, timeout handling, and recent-output buffering first so 146 can move remote command construction separately.
