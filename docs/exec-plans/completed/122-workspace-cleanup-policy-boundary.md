# 122 Workspace Cleanup Policy Boundary

## Goal

Centralize destructive workspace cleanup decisions behind a small policy boundary before local or remote deletion commands run.

## Status

Completed.

## Background

Workspace code intentionally deletes issue workspaces and stale worktree paths. Current deletion behavior is embedded inside the large `Workspace` module and remote shell snippets:

- local `File.rm_rf!` during workspace creation/removal and worktree cleanup;
- remote `rm -rf "$workspace"` during SSH workspace preparation;
- tests that assert generated `rm -rf` behavior.

Clean starts are intentional, but destructive operations should be owned by a small validation/policy module.

## Scope

- Add a workspace cleanup policy boundary for validating deletion targets and reasons.
- Route local cleanup through that boundary.
- Generate remote cleanup scripts only after the same policy accepts the target.
- Cover root containment, blank paths, source repository protection, stale worktrees, and normal issue workspace cleanup.

## Out of Scope

- Removing clean-start behavior.
- Redesigning workspace layout.
- Changing source strategy semantics.
- Changing remote SSH execution transport.

## Acceptance Criteria

- Every workspace deletion path uses one validation/policy boundary.
- Remote cleanup command generation cannot bypass the policy.
- The policy rejects blank paths, outside-root paths, and source repository paths.
- Normal issue workspace cleanup and stale worktree cleanup still work.

## Test Cases

- Unit tests for cleanup policy decisions.
- Existing workspace creation/removal tests.
- Existing worktree strategy tests.
- Existing remote SSH script tests.

## Implementation Notes

Separate policy from shell rendering. The policy should return structured decisions; local and remote callers should render them differently.

## Verification

- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/dynamic_atom_usage_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_cleanup_policy_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/coverage_ignore_governance_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_startup_test.exs test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_update_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_source_preparation_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix test --cover` (418 tests, 0 failures, 2 skipped, total coverage 85.72%)
- `mise exec -- mix lint`

## Completion Deviations

None.

## Dependencies

- Completed plan 058.
- Completed plan 096.
- Completed plan 117.

## Handoff Notes

Keep the behavior boring: validate, log reason, delete. Avoid making cleanup configurable unless a separate product decision requires it.
