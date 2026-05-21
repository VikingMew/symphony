# 117 Worktree Merge Base Branch Checkout

## Goal

Fix the backend merge flow so it supports any configured base branch name, including `master`, `main`, or a project-specific branch, when the project uses `source_strategy: worktree`.

The merge phase must not fail merely because the configured base branch is already checked out by the managed repository cache or another Git worktree.

## Status

Completed.

## Background

A merge run failed with:

```text
Failure class=agent_domain_failure reason={:git_command_failed, ["checkout", "master"], 128, "fatal: 'master' is already used by worktree at '/Users/mew/.symphony/repositories/claude-code-router-rust-8a7405193c9b'\n"}
```

This is not a Codex sandbox, approval-policy, or `danger-full-access` issue. It is a Git worktree constraint exposed by Symphony's backend merge implementation.

The current merge path resolves `base_branch` from the merge profile's `base_branch` or from `project.default_branch`, then calls `Git.merge_branch/3`. `Git.merge_branch/3` fetches the Linear branch and runs `git checkout <base_branch>` before `git merge --no-edit origin/<branchName>`.

That works in a plain clone, but it is unsafe in worktree mode. Git does not allow the same local branch to be checked out in two worktrees at once. The managed base repository commonly has the configured default branch checked out already, so attempting to check out that same local branch in an issue or merge worktree can fail. The problem is the checkout strategy, not the branch name. `master`, `main`, and any valid configured base branch must all be supported.

Completed plan 073 specified that merge should check out the configured base branch. Completed plan 100 later added worktree base-repository syncing. The interaction between those two behaviors left a gap: merge still assumes local base-branch checkout is available, while worktree source preparation deliberately keeps a shared base repository with the default branch.

## Scope

- Update the backend merge git flow so it does not directly check out the shared local base branch in a worktree workspace.
- Preserve support for arbitrary configured base branch names:
  - `master` is valid when configured.
  - `main` is valid when configured.
  - project-specific branch names are valid if they pass the existing branch/ref validation boundary.
- Fetch and validate both:
  - the Linear `branchName` to merge;
  - the configured base branch from the configured remote.
- Merge `origin/<branchName>` against the latest `origin/<base_branch>` without requiring `git checkout <base_branch>` in the worktree.
- Keep push behavior explicit:
  - when `push: false`, perform only the merge validation and record the result;
  - when `push: true`, update the configured remote base branch only after the merge succeeds.
- Record session/run history details that distinguish:
  - missing remote feature branch;
  - missing remote base branch;
  - worktree local-branch checkout conflict;
  - merge conflict;
  - push failure.
- Add tests covering worktree mode and branch-name variants.

## Out of Scope

- Do not declare `master` an invalid or deprecated branch name.
- Do not require users to rename repositories from `master` to `main`.
- Do not solve merge conflicts automatically.
- Do not change Linear `branchName` ownership or derive fallback branch names.
- Do not change Codex sandbox, approval policy, or prompt behavior for this issue.
- Do not remove clone-mode merge support.

## Acceptance Criteria

- A worktree-backed merge run with `base_branch: "master"` does not run `git checkout master` in the issue/merge worktree.
- A worktree-backed merge run with `base_branch: "main"` does not run `git checkout main` in the issue/merge worktree.
- The merge flow works when the managed base repository already has the configured base branch checked out.
- The merge flow fetches and validates the remote base branch before merge.
- The merge flow fetches and validates the Linear branch before merge.
- With `push: false`, a successful merge validation does not push.
- With `push: true`, a successful merge pushes the result to the configured remote base branch.
- A missing remote base branch fails before merge with a clear, specific error.
- A missing remote Linear branch still fails before merge with the existing remote-branch-not-found behavior or a clearer equivalent.
- Merge conflict failures remain visible and sanitized.
- Existing clone-mode merge behavior remains compatible.

## Test Cases

- Worktree merge with base `master`:
  - managed base repository has local `master` checked out;
  - merge workspace attempts to merge a remote Linear branch;
  - command sequence does not include `git checkout master`;
  - merge succeeds or validates without the worktree checkout conflict.
- Worktree merge with base `main`:
  - same as above, using `main`.
- Worktree merge with a custom configured base branch:
  - base branch exists on the remote;
  - merge flow uses that branch as the merge base without checking out the local branch directly.
- Missing remote base branch:
  - `origin/<base_branch>` does not exist;
  - merge fails before attempting merge;
  - failure reason identifies the missing base branch.
- Missing remote Linear branch:
  - `origin/<branchName>` does not exist;
  - merge fails before attempting merge.
- Merge conflict:
  - remote base and Linear branch exist;
  - merge exits non-zero;
  - run records sanitized conflict output and does not push.
- Push disabled:
  - merge succeeds;
  - no push command is issued.
- Push enabled:
  - merge succeeds;
  - result is pushed to `refs/heads/<base_branch>` on the configured remote.
- Clone mode regression:
  - existing clone-mode tests continue to pass.

## Implementation Notes

Prefer one of these implementation strategies:

1. Create a unique temporary merge branch from the fetched remote base ref, for example `symphony/merge/<issue>/<run-id>`, then merge `origin/<branchName>` into that temporary branch. When `push: true`, push the temporary branch HEAD to `refs/heads/<base_branch>`. Clean up the local temporary branch when practical.
2. Use detached HEAD at `origin/<base_branch>`, merge `origin/<branchName>`, and push `HEAD:refs/heads/<base_branch>` when `push: true`.

The temporary-branch approach is easier to inspect in logs and avoids detached-HEAD edge cases. The branch name must be unique per merge run so parallel or retried merges do not collide.

Do not use `git checkout <base_branch>` for worktree merge execution. If clone mode keeps using that command temporarily, isolate the behavior so worktree mode cannot hit the shared-branch checkout constraint. A cleaner long-term solution is to use the same remote-base merge strategy for both clone and worktree modes.

The command boundary should continue using argv-style git execution, not shell interpolation.

Relevant current code:

- `SymphonyElixir.MergeExecutor.run/3` resolves `base_branch` from profile/project settings.
- `SymphonyElixir.Git.merge_branch/3` currently fetches the feature branch, checks out the base branch, merges, and optionally pushes.
- `SymphonyElixir.Workspace` worktree preparation updates the managed base repository's local default branch from `origin/<default_branch>`, which makes direct checkout of that same branch from another worktree unsafe.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/merge_flow_test.exs`
- Focused tests for `SymphonyElixir.Git.merge_branch/3` command ordering.
- Focused worktree integration test covering a base repository with the base branch already checked out.
- `mise exec -- mix lint`
- `git diff --check`

## Completion Deviations

- Used the detached `origin/<base_branch>` strategy from the implementation notes instead of a
  temporary merge branch. Push now explicitly sends `HEAD:refs/heads/<base_branch>`.
- Applied the remote-base merge strategy to `Git.merge_branch/3` for both clone and worktree
  callers, so clone mode keeps working while worktree mode avoids local branch checkout conflicts.

## Dependencies

- Completed plan 073 for backend-owned merge from Linear `branchName`.
- Completed plan 090 for project-owned workspace source strategy.
- Completed plan 091 for worktree source strategy runtime.
- Completed plan 096 for shared workspace source root layout.
- Completed plan 100 for syncing the configured default branch before creating worktrees.

## Handoff Notes

Treat this as a code defect in merge/worktree compatibility, not as a user configuration error. Operators may configure `master`, `main`, or another valid base branch. Symphony's merge implementation must avoid local branch checkout assumptions that are invalid under Git worktree semantics.
