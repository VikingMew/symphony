# 096 Workspace Source Root Layout

## Goal

Refactor source path configuration so worktree mode uses two clear shared base roots: one for cached base repositories and one for per-issue worktrees. The runtime should derive concrete paths by appending a stable repo cache name to the repository base root and the issue identifier to the worktree base root. These roots are not project-level settings.

## Status

Completed.

## Background

Current worktree configuration can produce confusing and invalid path combinations. A run can derive a Codex cwd such as:

```text
/Users/mew/.symphony/worktree/ccr/CCR-5
```

while sandbox validation still expects:

```text
/private/tmp/symphony-workspaces
```

That fails as `{:invalid_workspace_cwd, :outside_workspace_root, cwd, root}`. The deeper design issue is that repository cache paths, issue worktree paths, clone workspace roots, and sandbox allowed roots are not presented as one coherent layout. The roots should be shared runtime/workspace configuration, while project records only provide project-specific source details such as repository URL, branch, depth, and strategy.

The long-term design is now documented in `docs/workspace_source_layout.zh-CN.md`.

## Scope

- Rename or reinterpret worktree settings into clear concepts:
  - `repository_base_root`;
  - `worktree_base_root`;
  - derived `repo_cache_name`;
  - derived issue worktree path.
- Store and edit `repository_base_root` and `worktree_base_root` as shared workflow/runtime workspace settings, not per-project settings.
- Keep project settings focused on repository URL, default branch, checkout depth, source strategy, fetch/cleanup policy, and setup/cleanup commands.
- For worktree source strategy, derive:
  - base repo path as `repository_base_root / repo_cache_name`;
  - issue worktree path as `worktree_base_root / issue_identifier`.
- Ensure final Codex cwd sandbox validation checks the derived issue worktree path against allowed roots.
- Update Settings UI labels and helper copy so users do not enter a full issue path.
- Show a preview of derived paths where users configure workspace/source layout.
- Update validation errors to point to the relevant user-editable field:
  - workflow/runtime repository base root;
  - workflow/runtime worktree base root;
  - sandbox allowed roots.
- Keep clone strategy behavior working while documenting how it relates to clone workspace root.
- Update tests that currently assume `worktree_base_path` is already the final base repo path.
- Update user guide and workflow page docs to point to the dedicated workspace source layout document.

## Out of Scope

- Do not redesign Codex sandbox policy.
- Do not change Linear issue identifier generation.
- Do not add remote worker path mapping beyond preserving existing behavior.
- Do not reintroduce hook-based clone/worktree setup.
- Do not preserve hidden legacy compatibility for old worktree path semantics; this is alpha.
- Do not implement a full migration wizard unless the current schema requires one to boot.

## Acceptance Criteria

- Worktree mode never stores or expects an issue-specific worktree path in Project Settings.
- Repository/worktree base roots are not project-level fields.
- A configured `repository_base_root` and `worktree_base_root` deterministically produce base repo and issue worktree paths.
- The default local layout keeps repositories and worktrees under one coherent Symphony root.
- The invalid path error for cwd outside sandbox roots becomes actionable and names the setting to change.
- Settings UI labels match the model:
  - "Repository base root";
  - "Worktree base root";
  - derived path previews.
- Existing clone strategy tests still pass.
- Worktree runtime tests cover:
  - base repo path derived from root plus repo cache name;
  - issue worktree path derived from root plus issue identifier;
  - sandbox validation accepts the derived worktree path when allowed roots include the worktree base root;
  - sandbox validation rejects it with a clear error when not allowed.

## Test Cases

- Configure worktree source strategy with:
  - repository URL `git@github.com:example/repo.git`;
  - project slug `ccr`;
  - repository base root `/tmp/symphony/repositories`;
  - worktree base root `/tmp/symphony/worktrees`.
- Assert base repo path is under `/tmp/symphony/repositories`.
- Assert issue `CCR-5` worktree path is `/tmp/symphony/worktrees/CCR-5`.
- Assert path derivation rejects `../escape` in project slug or issue identifier normalization.
- Assert stale worktree cleanup only removes the derived issue worktree path.
- Assert shared workflow/runtime settings save and reload preserve roots, not fully derived issue paths.
- Assert project save and reload does not include repository/worktree base roots.
- Assert UI preview renders the example derived paths.
- Assert `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs` passes.

## Implementation Notes

- Prefer adding explicit shared schema fields if current names are too ambiguous. If reusing current persisted fields temporarily, wrap them behind clearly named code functions so the rest of runtime speaks in `repository_base_root` and `worktree_base_root`.
- The repo cache name should be stable and path-safe. A practical format is `<project_slug>-<short_hash(repository_url + default_branch)>`.
- Keep all path expansion and validation centralized in `SymphonyElixir.Workspace`.
- Keep generated system progress labels from plan 095; this change should not make clone/worktree silent again.
- If database schema changes are needed, update tests and docs directly rather than adding legacy compatibility branches.
- Update any `worktree_base_path` wording in docs/UI that currently suggests a complete base repository path or a project-owned root.

## Verification

- Passed `mise exec -- mix format`.
- Passed focused regression tests:
  - `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/app_server_test.exs`
- Passed `mise exec -- mix lint`.
- Passed `mise exec -- mix build`.
- Passed `mise exec -- mix test` with 355 tests, 0 failures, 2 skipped.
- Passed `mise exec -- mix format --check-formatted`.
- Passed `git diff --check`.

## Completion Deviations

- The delivered repo cache name uses the repository basename plus a short hash of `repository_url:default_branch` rather than the project slug. This keeps cache names stable across project renames while still avoiding collisions between branches or URLs.
- The schema removes project-level `worktree_base_path` and `worktree_root` columns instead of translating them forward; this matches the alpha-stage no-legacy-compatibility policy.
- Sandbox cwd validation now accepts both the clone workspace root and the shared worktree base root for local runs, so worktree-derived issue paths are valid without making project records carry runtime roots.

## Dependencies

- Completed plan 090 for project-owned workspace source strategy.
- Completed plan 091 for worktree source strategy runtime.
- Completed plan 094 for worktree bootstrap timeout boundary.
- Completed plan 095 for system progress presentation.
- `docs/workspace_source_layout.zh-CN.md`.

## Handoff Notes

The product model is two roots plus derived paths. Do not solve the current error by adding one more ad hoc allowed path. The fix should make the path model obvious in Settings and impossible to misread at runtime.
