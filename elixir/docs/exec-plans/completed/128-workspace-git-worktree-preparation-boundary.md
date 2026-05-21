# 128 Workspace Git Worktree Preparation Boundary

## Goal

Extract project source preparation, git command orchestration, and worktree setup policy out of `SymphonyElixir.Workspace` into a focused boundary.

## Status

Completed.

## Background

`Workspace` still combines several responsibilities:

- local and remote workspace creation;
- project source strategy dispatch;
- clone setup;
- worktree base repository cache management;
- worktree fetch/update/prune/remove/add steps;
- git command execution and output handling;
- hook execution and progress event emission;
- cleanup safety checks.

Plan 122 covers destructive cleanup policy specifically. This plan covers the separate source-preparation problem: git/worktree setup is a coherent boundary and should not stay interleaved with generic workspace and hook code.

## Scope

- Extract a project source preparation module for `clone` and `worktree` strategy execution.
- Move worktree base repository path/key calculation into the new boundary or a small supporting module.
- Move worktree git steps into named operations:
  - ensure base repository;
  - fetch base branch;
  - update local base branch ref;
  - cleanup stale worktree;
  - add issue worktree.
- Keep hook execution in `Workspace` unless a later plan extracts hooks separately.
- Preserve existing progress events and error shapes unless a test proves a clearer shape is required.

## Out of Scope

- Changing workspace directory layout.
- Changing source strategy semantics.
- Changing cleanup policy covered by plan 122.
- Changing backend merge behavior covered by plan 117.
- Rewriting SSH execution.

## Acceptance Criteria

- `Workspace` delegates project source preparation to a named boundary.
- Worktree setup operations are individually testable without running the full workspace lifecycle.
- Existing clone and worktree tests pass.
- Existing progress event names remain stable or are intentionally updated with tests/docs.
- The extracted boundary does not own lifecycle hook execution.

## Test Cases

- Clone strategy prepares source with repository URL, branch, and setup timeout.
- Worktree strategy ensures/clones base repository when missing.
- Worktree strategy fetches and updates the configured base branch.
- Worktree strategy handles missing repository URL and invalid base repository clearly.
- Worktree cleanup delegates to the cleanup policy from plan 122 when both plans intersect.
- Existing `workspace_and_config_test`, `core_test`, and merge/worktree tests remain green.

## Implementation Notes

Keep the first extraction behavior-preserving. The value is a smaller reviewable ownership boundary, not new git behavior.

Use `SymphonyElixir.Git` where it fits. If `Workspace` still needs streaming progress from git commands, make that explicit in the new boundary's API instead of hiding it behind side effects.

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

- Active plan 122.
- Completed plan 090.
- Completed plan 096.
- Completed plan 117.

## Handoff Notes

Do this after or alongside plan 122 carefully. Cleanup safety and source preparation touch the same worktree paths but should remain separate concepts.
