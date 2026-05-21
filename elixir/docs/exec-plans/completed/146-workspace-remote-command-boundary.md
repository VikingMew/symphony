# 146 - Workspace Remote Command Boundary

Status: Completed

## Problem

`SymphonyElixir.Workspace` contains remote workspace creation, remote removal, remote hook execution support, shell assignment, remote output parsing, and SSH command invocation details.

Remote execution is a cross-cutting adapter concern, not core workspace lifecycle policy. Keeping it embedded makes local workspace behavior harder to read and makes remote behavior harder to test independently.

## Goal

Extract remote workspace command construction and execution into a small boundary such as `SymphonyElixir.Workspace.Remote`.

The boundary should own remote shell script construction, worker-host logging labels, remote command timeouts, and output parsing.

## Plan

1. Inventory remote-only helpers in `workspace.ex`, including remote ensure/remove paths, hook command execution, `remote_shell_assign/2`, `parse_remote_workspace_output/1`, and `run_remote_command/3`.
2. Define a narrow API for remote ensure, remove, and command execution.
3. Move remote command construction and output parsing into the new module.
4. Keep workspace lifecycle ordering in `Workspace`.
5. Add focused tests for quoted remote paths, malformed remote output, timeout/error propagation, and command script shape.
6. Ensure local-only workspace tests do not need to understand remote helpers.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace/remote_test.exs test/symphony_elixir/workspace_and_config_test.exs`
  - Result: `63 tests, 0 failures`.
- `rg -n "ensure_remote|remote_shell_assign|parse_remote_workspace_output|run_remote_command|defp .*remote|SSH\\.run|worker_host" elixir/lib/symphony_elixir/workspace.ex elixir/lib/symphony_elixir/workspace elixir/test/symphony_elixir/workspace elixir/test/symphony_elixir/workspace_and_config_test.exs`
  - Result: no old private remote shell/parser/command helpers remain in `Workspace`; SSH command execution is isolated in `Workspace.Remote`.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Remote command timeout behavior is covered through the extracted API shape and existing workspace fake SSH tests rather than a direct `run_command/3` timeout unit test, because the timeout path depends on the SSH task boundary.
