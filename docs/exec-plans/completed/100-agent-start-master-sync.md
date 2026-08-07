# 100 Agent Start Master Sync

## Goal

Ensure every agent run starts from the latest configured base branch. Before creating or reusing an issue worktree, Symphony should update the project's base repository from its remote `master`/default branch so the agent does not work from stale code.

## Status

Completed.

## Background

The workspace source flow now separates project repository settings from workflow bootstrap commands. For `source_strategy: worktree`, Symphony prepares a cached base repository under the shared repository base root and creates issue worktrees under the shared worktree base root. That architecture only works reliably if the base repository is refreshed before each agent run.

Users expect a new agent attempt to see current upstream code. If the cached base repository is stale, the generated worktree can miss recent fixes, fail against old files, or create branches from the wrong commit. This should be an explicit runtime behavior, not a user-authored hook, because it is part of source preparation.

The wording "pull master" should map to the project's configured `default_branch`. If a project sets `default_branch: master`, sync `master`; if it sets `main`, sync `main`.

## Scope

- Add an explicit pre-agent source sync step for project worktree source preparation.
- For `source_strategy: worktree`, before worktree creation/reuse:
  - ensure the base repository exists or clone it;
  - fetch the configured remote branch;
  - update the local base branch to the fetched remote branch;
  - create the issue worktree from that updated base branch.
- Treat `project.default_branch` as the branch to sync, not a hardcoded branch name.
- Keep `fetch_before_worktree` semantics, but make the operator-facing behavior clear: enabled means the base repo is refreshed before each agent workspace is prepared.
- Emit session history/system progress events for:
  - base repo fetch started;
  - base branch updated;
  - worktree created/reused.
- Surface failures with actionable messages that include project, repository URL, branch, and whether the failure happened during fetch, branch update, or worktree creation.
- Update Settings labels/docs so operators understand the option controls source freshness before each agent run.
- Add tests covering fresh clone, existing base repository fetch/update, and failure handling.

## Out of Scope

- Do not put `git pull` into lifecycle hooks.
- Do not force every project to use a branch literally named `master`.
- Do not auto-merge user worktree changes into the base repository.
- Do not change Codex startup behavior in this plan.
- Do not implement scheduled background repository sync; this is per-agent-start source preparation.

## Acceptance Criteria

- Each agent run using worktree source strategy updates the base repository from the configured remote branch before the issue worktree is prepared.
- Project `default_branch` controls the branch name; `master` is only used when configured.
- Existing issue worktree reuse is safe:
  - clean stale worktrees can be recreated from the fresh base when the cleanup option requires it;
  - dirty worktrees are not silently overwritten.
- Source sync progress appears in session history/system updates so the user can see what the agent is doing before Codex starts.
- Fetch or branch update failures stop the agent attempt before Codex starts and are classified as workspace/source preparation failures.
- Retry behavior remains owned by the orchestrator; a failed source sync schedules retry according to existing retry policy.
- No workflow hook is required to keep the source fresh.

## Test Cases

- Worktree source with an empty base repo cache clones the configured repository and checks out the configured default branch.
- Worktree source with an existing base repo fetches the remote and updates the local default branch before creating the issue worktree.
- A project configured with `default_branch: "master"` syncs `origin/master`; a project configured with `default_branch: "main"` syncs `origin/main`.
- A fetch failure returns a source-preparation error and does not start Codex.
- A branch update failure returns a source-preparation error and does not start Codex.
- Session history receives progress events for fetch/update/worktree preparation.
- Existing tests that previously depended on hooks for clone behavior no longer require hook-based clone setup.

## Implementation Notes

- Implement this inside the workspace/source preparation layer, not in `AgentRunner` as a generic shell hook.
- Prefer explicit git commands over `git pull` where possible:
  - `git fetch origin <branch>`;
  - update or reset the local base branch to `origin/<branch>` only inside the managed base repository.
- Keep managed base repo paths under the shared repository base root. Do not use issue worktree paths as base repositories.
- The existing `fetch_before_worktree` project setting can remain the boolean switch; rename or clarify label if needed.
- Sanitize git output before logging, preserving useful progress and errors.
- Remote worker execution must apply the same sync behavior on the selected worker host.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- Focused workspace/source tests for clone, fetch/update, branch selection, failure, and progress events.
- `git diff --check`

## Completion Deviations

Implemented in the workspace source preparation layer. The delivered sync uses `git fetch origin <default_branch> --prune` followed by `git update-ref refs/heads/<default_branch> refs/remotes/origin/<default_branch>` inside the managed base repository before `git worktree add`.

Verified with focused workspace tests that a second issue worktree sees a new commit pushed to the configured default branch and that the managed base branch matches the source branch head.

## Dependencies

- Completed plan 090 for project-owned workspace source strategy.
- Completed plan 091 for worktree source strategy runtime.
- Completed plan 094 for workspace bootstrap timeout and stall boundary.
- Completed plan 096 for shared workspace source root layout.

## Handoff Notes

This plan is about source freshness before each agent run. The product behavior should be "agent starts from the latest configured default branch" without asking the user to write git commands in hooks. Keep the branch configurable through Project Settings, and keep all source preparation output visible as system progress before Codex starts.
