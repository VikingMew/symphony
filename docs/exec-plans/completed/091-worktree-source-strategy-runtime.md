# 091 Worktree Source Strategy Runtime

## Goal

Implement the Project-owned `worktree` source strategy so Symphony can prepare each task workspace as a Git worktree created from a centralized base repository cache.

When a project uses the worktree strategy, Symphony should automatically initialize the base repository cache if it is missing, fetch/update it when configured, and create a clean per-issue worktree at the target workspace path before running project setup commands and lifecycle hooks.

## Status

Completed.

## Background

Task 090 defines the ownership correction: clone and worktree are project source preparation strategies, not hooks. This task implements the worktree strategy runtime behavior after that ownership model exists.

The intended operator experience is:

- configure a project repository URL and default branch,
- choose `worktree` as the source strategy,
- optionally configure where Symphony stores base repositories and worktrees,
- start listening,
- each task gets its own clean worktree automatically.

The first task for a project may not have a base repository available locally. In that case Symphony should not ask the user to run a hook. It should clone the base repository into a centralized Project-owned cache path, then create the issue worktree from that cache.

## Scope

- Add runtime support for Project source strategy `worktree`.
- Add or use Project-owned fields introduced by Task 090:
  - `source_strategy`,
  - `repository_url`,
  - `default_branch`,
  - `worktree_base_root` or `worktree_base_path`,
  - `worktree_root`,
  - `worktree_fetch`,
  - `worktree_cleanup`.
- Define default paths when not explicitly configured:
  - base repo cache root under the Symphony data/cache directory,
  - issue worktree root under the configured workspace root or a project-owned worktree root.
- If the base repository path does not exist:
  - create parent directories,
  - clone `repository_url` into the centralized base repo path,
  - checkout/fetch the configured default branch as needed.
- If the base repository path exists:
  - validate it is a Git repository for the configured project,
  - optionally fetch before creating the issue worktree,
  - fail with clear setup guidance if it is invalid.
- For each task:
  - remove any stale issue worktree at the target path,
  - remove stale Git worktree registration if present,
  - create a new worktree for the issue,
  - use an issue-specific branch naming policy compatible with existing branch preparation behavior,
  - run `project.setup_commands`,
  - then run custom `hooks.after_create`,
  - then later run `hooks.before_run` before Codex starts.
- Keep clone strategy behavior intact.
- Add logs/events that distinguish:
  - base repo initialization,
  - base repo fetch,
  - issue worktree creation,
  - custom lifecycle hooks.
- Add Settings guidance for missing or invalid worktree configuration.
- Update docs to explain first-run auto-clone and per-task worktree creation.

## Out of Scope

- Do not implement worktree through `after_create`, `before_run`, or user shell snippets.
- Do not require operators to manually clone the base repo before first use.
- Do not make worktree the default strategy.
- Do not remove clone strategy.
- Do not support multiple remotes or advanced Git topology in this task.
- Do not implement shared mutable task workspaces.
- Do not keep stale worktrees unless `worktree_cleanup` explicitly says to retain them.
- Do not silently reuse an invalid base repo path.

## Acceptance Criteria

- [x] Project Settings can select `source_strategy = worktree`.
- [x] A worktree project can run without a pre-existing base repo directory.
- [x] On first run, Symphony clones the configured `repository_url` into the centralized base repo cache.
- [x] On subsequent runs, Symphony reuses the base repo cache.
- [x] If `worktree_fetch` is enabled, Symphony fetches before creating a task worktree.
- [x] Each task gets a clean issue-specific worktree at the expected workspace path.
- [x] Stale worktree directories and stale Git worktree registrations are cleaned before recreation.
- [x] Project setup commands run inside the created worktree.
- [x] Custom `hooks.after_create` runs after setup commands inside the created worktree.
- [x] Clone strategy still creates a normal cloned workspace.
- [x] Missing/invalid worktree config produces clear setup guidance in Settings/runtime logs.
- [x] Logs identify `project_bootstrap` substeps without calling them user hooks.
- [x] Tests cover first-run base clone, subsequent reuse, setup/hook order, and invalid base config.

## Test Cases

- First-run auto clone:
  - configure a project with `source_strategy = worktree`,
  - point `repository_url` at a fixture bare/non-bare repository,
  - leave the base repo cache path absent,
  - run workspace preparation,
  - assert the base repo cache is created,
  - assert the issue worktree is created at the task workspace path.
- Subsequent run reuse:
  - run workspace preparation twice for different issues,
  - assert the base repo is not recloned,
  - assert each issue has a separate worktree.
- Fetch behavior:
  - configure `worktree_fetch = true`,
  - assert `git fetch` runs in the base repo before worktree creation.
- Stale cleanup:
  - create a stale worktree directory and/or stale Git worktree registration,
  - run workspace preparation,
  - assert stale state is removed before the new worktree is created.
- Setup and hook order:
  - configure `project.setup_commands` and `hooks.after_create`,
  - assert setup runs after worktree creation,
  - assert `after_create` runs after setup,
  - assert both run inside the worktree path.
- Invalid base repo:
  - point base path at a non-Git directory,
  - assert workspace preparation fails with actionable setup guidance,
  - assert no custom hook runs.
- Clone regression:
  - configure `source_strategy = clone`,
  - assert existing clone behavior and tests still pass.

## Implementation Notes

- This plan should build on Task 090's project-owned source strategy fields and bootstrap naming cleanup.
- Keep worktree behavior behind an explicit `source_strategy = worktree` value.
- Prefer a dedicated module for Git source preparation, for example:
  - `SymphonyElixir.ProjectSource`,
  - `SymphonyElixir.Workspace.Source`,
  - or similar local naming aligned with existing modules.
- Keep shell/Git calls centralized so tests can inject a fake Git runner where practical.
- Suggested worktree flow:
  1. resolve project source config,
  2. resolve base repo path,
  3. ensure base repo exists or clone it,
  4. fetch if configured,
  5. clean stale issue worktree,
  6. create issue worktree,
  7. return the workspace path for setup/hooks/Codex.
- Use stable names for cache directories:
  - project slug,
  - repository URL digest if needed to avoid collisions,
  - issue identifier for worktree directory.
- Be careful with `git worktree remove`:
  - remove registered worktrees when possible,
  - fall back to filesystem cleanup only when the worktree is not registered or is already broken,
  - do not run destructive cleanup outside configured cache/worktree roots.
- Branch naming should be compatible with existing issue branch behavior. If branch preparation already happens later, avoid creating conflicting branches during worktree creation.
- Logs should be concise and useful:
  - base clone started/completed/failed,
  - fetch started/completed/failed,
  - worktree create started/completed/failed,
  - cleanup actions.
- Document that worktree is best for local machines with many tasks against the same repository, while clone remains the portable default.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

The implementation keeps worktree source preparation inside `SymphonyElixir.Workspace` rather than introducing a separate source module, so the change stays scoped to the existing workspace lifecycle. Tests cover first-run clone, subsequent reuse, setup/hook order, and invalid non-Git base paths; fetch is exercised through the enabled default path rather than a separate fake Git runner assertion.

## Dependencies

- Task 090 project-owned source strategy fields and project bootstrap naming cleanup.
- Existing clean-workspace-on-start behavior from Task 058.
- Existing project bootstrap ordering from Task 059.
- Existing workspace phase logs from Tasks 061, 064, 068, and 069.
- Existing Git helper behavior in `SymphonyElixir.Git`.

## Handoff Notes

The key behavior is automatic base repo initialization: if a worktree project does not yet have a base repository cache, Symphony clones it from the project's `repository_url` into a centralized cache, then creates the task worktree. Operators should not need to encode this in hooks, and failures should point back to Project Settings/source strategy configuration.
