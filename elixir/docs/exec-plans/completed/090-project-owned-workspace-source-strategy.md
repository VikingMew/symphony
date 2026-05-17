# 090 Project-Owned Workspace Source Strategy

## Goal

Move all repository checkout/source preparation settings into Project Settings and make workspace preparation a first-class project bootstrap phase instead of a generated hook.

The operator should understand that clone and worktree are two strategies for preparing code for an issue workspace. Neither strategy belongs in `after_create`, `before_run`, or any other user lifecycle hook.

## Status

Completed.

## Background

The current product model has been moving project-specific values out of Workflow and into Project Settings. Repository URL, Linear project slug, and default branch are already project-owned. Checkout depth still appears in Workflow, and the internal bootstrap path still uses names like `generated_after_create_hook`, which makes repository checkout look like a hook.

That is conceptually wrong:

- Project Settings owns where code comes from and how workspace source is prepared.
- Workflow owns state routing, lifecycle policy, hooks, and agent behavior.
- Hooks are optional commands that run after the workspace source already exists.

This also matters for `git worktree`. A worktree is not a prehook. It is an alternative source preparation strategy at the same layer as clone:

- clone strategy: create a fresh checkout from `repository_url`,
- worktree strategy: create an issue worktree from an existing local repository.

The implementation should rename the runtime concepts so logs, docs, and code stop implying that project checkout is a generated `after_create` hook.

## Scope

- Move checkout depth ownership from Workflow Settings to Project Settings.
- Persist checkout depth per project.
- Display and edit checkout depth on each project card.
- Remove checkout depth from the Workflow Settings Bootstrap section.
- Keep workflow export/import using the active/default project's project settings when generating the runtime workflow configuration.
- Rename internal generated bootstrap APIs away from hook terminology:
  - replace `generated_after_create_hook` naming with `generated_project_bootstrap_commands` or equivalent,
  - keep execution labels/logs as `project_bootstrap` / `workspace_bootstrap`.
- Make the workspace preparation order explicit in code and docs:
  1. create a clean issue workspace,
  2. prepare source from Project Settings,
  3. run project setup commands,
  4. run custom `hooks.after_create`,
  5. run `hooks.before_run`,
  6. start Codex.
- Add a project source strategy model in Project Settings:
  - initial supported strategy: `clone`,
  - planned strategy option: `worktree`.
- Do not implement full worktree execution unless it can be done cleanly in this task. At minimum, the schema/UI/docs should reserve a clear `source_strategy` ownership point so worktree can be added without using hooks.
- If implementing worktree in this task, support project-owned fields such as:
  - source strategy,
  - base repository path,
  - worktree root or issue worktree directory policy,
  - fetch before worktree creation,
  - cleanup policy.
- Ensure hook UI copy says hooks run after project source preparation.
- Update long-term docs and user guide to explain clone/worktree as project source strategies, not hooks.

## Out of Scope

- Do not put clone commands or worktree commands in `after_create` or `before_run`.
- Do not preserve legacy UI placement for checkout depth.
- Do not keep old generated-hook naming except through temporary private wrappers if required during migration.
- Do not make Workflow own repository URL, default branch, checkout depth, or source strategy.
- Do not create an import CLI or workflow-file compatibility path.
- Do not redesign all Project Settings layout beyond what is needed for source strategy fields.
- Do not implement arbitrary shell snippets for source preparation.
- Do not require every project to use worktree.

## Acceptance Criteria

- [x] Project Settings shows checkout depth with repository URL and default branch.
- [x] Saving a project persists checkout depth.
- [x] Workflow Settings no longer shows checkout depth as a Workflow-owned field.
- [x] Runtime workflow generation still includes the selected project's checkout depth for clone-based checkout.
- [x] Project bootstrap code no longer exposes `generated_after_create_hook` as the primary API name.
- [x] Workspace execution logs and phases clearly distinguish `project_bootstrap` from custom `after_create`.
- [x] `hooks.after_create` runs only after project source preparation and setup commands.
- [x] Documentation states clone/worktree are project source strategies.
- [x] Documentation states hooks are post-source lifecycle commands.
- [x] Tests cover clone checkout depth coming from Project Settings.
- [x] Tests cover that removing checkout depth from Workflow does not remove runtime checkout behavior.
- [x] If worktree is implemented, tests cover successful worktree creation and invalid base path behavior.

## Test Cases

- Project Settings:
  - edit checkout depth on the default project,
  - save,
  - assert the persisted project has the new depth,
  - assert save feedback still shows saving/saved/failure states.
- Workflow Settings:
  - open Workflow tab,
  - assert checkout depth is not rendered as a Workflow field,
  - assert project checkout/source copy points to Settings / Projects.
- Runtime export:
  - save a project with repository URL, default branch, and checkout depth,
  - save workflow settings,
  - assert exported raw workflow contains the project-owned checkout depth.
- Workspace bootstrap:
  - configure clone strategy,
  - assert generated project bootstrap commands include clone, branch, depth, repository URL, and setup commands,
  - assert custom `after_create` runs after generated project bootstrap.
- Naming cleanup:
  - search for `generated_after_create_hook`,
  - assert no public/runtime-facing call path uses that name after the rename.
- Worktree reservation:
  - if only reserving the model, assert unsupported worktree config fails with clear setup guidance instead of falling back to hooks.
- Worktree implementation, if included:
  - use a fixture local repository,
  - create an issue worktree under the configured worktree root,
  - assert setup commands and `after_create` run inside that worktree,
  - assert cleanup removes the worktree registration and directory according to policy.

## Implementation Notes

- Prefer adding project-owned fields to the project persistence schema rather than storing them in workflow-only config.
- Candidate project fields:
  - `checkout_depth`,
  - `source_strategy`,
  - `worktree_base_path`,
  - `worktree_root`,
  - `worktree_fetch`,
  - `worktree_cleanup`.
- Keep `clone` as the default source strategy.
- Treat `worktree` as a project source strategy, not as a lifecycle hook.
- If full worktree support is too large for this plan, add only explicit schema/UI/docs placeholders when they cannot accidentally enable a broken runtime path.
- Rename runtime helpers deliberately:
  - old concept: generated after-create hook,
  - new concept: generated project bootstrap commands.
- Avoid stringly conflation in logs:
  - generated source/setup: `hook=project_bootstrap`, phase `workspace_bootstrap`,
  - custom hook: `hook=after_create`, phase `workspace_after_create`.
- Keep `project.setup_commands` after source preparation and before custom hooks.
- Settings save semantics must remain unchanged:
  - parseable settings can save,
  - semantic/runtime checks guide setup,
  - page-owned check failures highlight page-owned fields.
- Update tests before deleting fields from Workflow UI so regressions are visible.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

Worktree runtime support was implemented together with this ownership cleanup instead of only reserving the model. Runtime logs now say `Running project bootstrap` for generated/project setup commands while preserving existing internal event names for hook event storage.

## Dependencies

- Multiple project settings from Task 084.
- Shared Settings validation and highlighting from Task 089.
- Existing project bootstrap order from Task 059.
- Existing workspace phase logging from Tasks 061, 064, 068, and 069.
- Current DB-only runtime workflow source model from Task 080.

## Handoff Notes

The core correction is conceptual: source preparation is owned by Project Settings and runs before hooks. Clone and worktree are peer strategies for preparing code. The implementation should remove UI and naming that makes repository checkout look like a prehook, while preserving the runtime order where custom `after_create` runs after project source and setup commands.
