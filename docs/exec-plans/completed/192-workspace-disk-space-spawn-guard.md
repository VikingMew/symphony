# 192 Workspace Disk Space Spawn Guard

## Goal

Prevent Symphony from spawning new agents when the configured Symphony workspace storage is low on disk space, and optionally reclaim old safe workspaces before deciding to block dispatch.

The minimum free-space threshold must be configurable. Automatic deletion must also be configurable because deleting workspaces is destructive even when they appear safe.

## Status

Completed.

## Background

Each agent run creates or reuses local workspace storage under the configured Symphony workspace layout. Worktree mode also keeps a repository cache and per-issue worktrees. When that filesystem fills up, new agent spawns can fail in the worst possible place: after an issue has been claimed or moved, during clone/worktree/bootstrap, or after Codex has started producing partial results.

The better boundary is before dispatch/spawn:

- inspect free space under the configured workspace root or the relevant repository/worktree root;
- if free space is below a configured minimum, do not start a new agent;
- optionally reclaim old, non-running, safe-to-delete workspaces;
- retry the free-space check after cleanup;
- if still below the threshold, keep listening/dispatch blocked for new work and show a clear operator reason.

There is already a destructive cleanup policy boundary from completed plan 122. This plan should build on that safety model rather than adding ad hoc deletion.

## Scope

- Add configurable workspace disk guard settings:
  - minimum free bytes, defaulting to `1 GiB`;
  - cleanup mode, defaulting to no automatic deletion;
  - optional cleanup target/retention settings such as maximum deleted workspaces per attempt or minimum age.
- Evaluate free space before spawning a local agent or creating a worker-backed workspace task.
- Decide which path to check:
  - clone workspace root for clone strategy;
  - worktree base root and repository base root for worktree strategy;
  - any configured workspace root that will receive run artifacts.
- If free space is below threshold and automatic cleanup is disabled, block new dispatch/spawn and record a clear event/reason.
- If automatic cleanup is enabled, delete the oldest eligible non-running workspace records until either:
  - free space is above threshold;
  - no eligible workspaces remain;
  - configured cleanup limits are reached.
- Re-check free space after each cleanup batch before starting new work.
- Define "eligible for automatic deletion" conservatively:
  - no active/running/leased task points to the workspace;
  - run is completed, failed, stopped, or otherwise no longer active;
  - workspace is not the current run workspace;
  - workspace path is inside an approved workspace root and passes `WorkspaceCleanupPolicy`;
  - workspace has no unpushed branch/output risk, or the run has recorded that required push/publication completed.
- Persist or derive enough metadata to know whether a workspace was pushed/published safely before deletion.
- Add dashboard/run-history/operator-visible status when dispatch is blocked by low disk.
- Add tests for guard decisions, cleanup eligibility, dispatch blocking, and cleanup-before-spawn behavior.

## Out of Scope

- Deleting repository caches by default.
- Deleting currently running workspaces.
- Deleting arbitrary directories outside configured Symphony roots.
- Inferring safety from fragile string matching of Git output alone.
- Making Codex itself responsible for cleanup.
- Solving disk pressure outside Symphony-managed workspace roots.
- Automatically pruning remote branches or GitHub resources.

## Acceptance Criteria

- Default minimum free space is `1 GiB`, and operators can configure it.
- Automatic workspace deletion is disabled by default unless explicitly configured.
- When available free space is below the threshold and cleanup is disabled, Symphony does not spawn a new agent.
- The blocked dispatch reason is visible in logs/events/dashboard state, including root path, available bytes, and configured threshold.
- When cleanup is enabled, Symphony deletes only eligible non-running safe workspaces, oldest first.
- Symphony re-checks free space after cleanup and only spawns the agent if the threshold is satisfied.
- If cleanup cannot free enough space, Symphony still blocks spawn and explains why.
- Running workspaces are never deleted by the automatic cleanup path.
- Workspaces with unpushed implementation output are not deleted by the automatic cleanup path.
- Every deletion path goes through the existing cleanup policy boundary or an equivalent shared policy with root-containment checks.
- The Settings UI or documented config exposes both the threshold and cleanup behavior.

## Test Cases

- Disk guard unit test: available bytes above threshold allows spawn.
- Disk guard unit test: available bytes below threshold blocks spawn when cleanup is disabled.
- Disk guard unit test: threshold can be configured to a non-default value.
- Cleanup eligibility test: running workspace is rejected.
- Cleanup eligibility test: workspace outside configured root is rejected.
- Cleanup eligibility test: completed pushed workspace is eligible.
- Cleanup eligibility test: completed but unpushed workspace is not eligible.
- Cleanup order test: eligible workspaces are selected oldest first.
- Cleanup limit test: max deletion count/age policy is respected.
- Orchestrator dispatch test: low disk prevents a local agent run before issue state mutation/spawn.
- Worker mode test: low disk prevents queueing or leasing work that would create a workspace on the constrained root.
- Recovery test: cleanup frees enough space, then the pending spawn proceeds.
- Failure test: cleanup deletion error records an event and does not continue deleting unrelated paths.

## Implementation Notes

- Prefer a small pure policy module, for example `WorkspaceDiskGuard` or `WorkspaceRetentionPolicy`, that receives:
  - configured roots;
  - free-space probe results;
  - workspace/run records;
  - cleanup settings.
- Keep the filesystem free-space probe injectable for tests. On Unix systems this can use `df`, Erlang/OTP disk APIs if suitable, or a focused port command wrapper; avoid parsing human-formatted output.
- Place the runtime check before any operation that claims a new issue or advances Linear state. It is better to skip dispatch than to start and fail mid-bootstrap.
- Consider separating decisions:
  - `:allow`;
  - `{:cleanup, candidates}`;
  - `{:block, reason}`.
- The "pushed" requirement needs an authoritative signal. Prefer persisted run/result metadata from implementation workflow or dynamic tool validation over scanning workspaces during cleanup.
- If the current persistence model cannot reliably prove pushed/published status, the initial implementation should block deletion of implementation workspaces unless an explicit `safe_to_delete` marker exists.
- Cleanup should emit events with bounded details:
  - workspace id/path;
  - reason;
  - bytes before/after if available;
  - deletion result.
- Settings should make the destructive behavior explicit:
  - `min_free_bytes` or `min_free_gib`;
  - `auto_cleanup_enabled`;
  - optional retention limits.
- Use binary units consistently. The default should be `1 GiB = 1_073_741_824 bytes` unless product copy deliberately says `1 GB`.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace_cleanup_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator/dispatch_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/worker_queue_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`
- Manual low-disk simulation or injected probe evidence:
  - below threshold with cleanup disabled blocks new spawn;
  - below threshold with cleanup enabled deletes eligible old safe workspace and then spawns only after threshold is satisfied.

## Completion Deviations

None.

## Dependencies

- Completed plan 058 for clean workspace-on-start behavior.
- Completed plan 091 for worktree source strategy runtime.
- Completed plan 096 for workspace source root layout.
- Completed plan 122 for workspace cleanup policy boundary.
- Completed plan 142 for orchestrator dispatch policy boundary.
- Completed plan 151 for persistence worker queue boundary.

## Handoff Notes

Be conservative. Low disk should stop new work before Symphony mutates external task state. Automatic deletion should be an explicit opt-in and should only delete workspaces that Symphony can prove are not running and safe to remove. If pushed/published status cannot be proven, prefer blocking spawn with a clear operator message over deleting useful work.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

