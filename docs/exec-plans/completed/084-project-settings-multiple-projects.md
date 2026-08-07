# 084 Move Project Settings Into Settings With Multiple Projects

## Goal

Move project configuration out of the standalone `/projects` surface and out of the Workflow settings form into Settings. Support multiple projects where each project owns its own repository URL, default branch, and Linear project slug, while global workflow/agent/runtime settings remain shared.

## Context

The current UI and persistence model still mix several concepts:

- `/projects` is a standalone read-only list, separate from Settings.
- `/settings/workflow` contains `Project slug`, `Repository URL`, and `Default branch` fields, which are actually project-specific values.
- The `projects` table currently stores only `name`, `slug`, `description`, and `enabled`.
- `tracker_configs` already has a project-scoped `project_slug`, but the settings UI currently edits project slug through the full workflow package.
- Workflow versions are still stored as complete runtime packages. That can continue for now, but Settings should not imply that repository URL/default branch/Linear project slug are global workflow fields.

The intended product model is:

- Settings is the entry point for configuration.
- Multiple projects can be configured from Settings.
- Each project has its own:
  - display name / internal slug,
  - Linear project slug,
  - repository URL,
  - default branch,
  - enabled flag.
- Other settings are shared:
  - active/terminal states,
  - assignee policy unless explicitly split later,
  - checkout depth,
  - setup/cleanup commands,
  - hooks,
  - workspace/runtime/codex settings,
  - workflow state routing,
  - agent profiles and prompts.

## Scope

- Add a Settings tab for project configuration, for example `/settings/projects`.
- Remove the standalone Projects nav/page as the primary project settings surface.
- Keep `/projects` only if routing compatibility is still required by existing tests/docs; otherwise remove it consistently with the current no-legacy-route direction.
- Extend persistence so each project can store:
  - repository URL,
  - default branch,
  - Linear project slug.
- Reuse or migrate `tracker_configs.project_slug` only if it keeps the data model simpler; avoid duplicating Linear project slug in two unrelated places without a clear source of truth.
- Add create/edit forms for multiple projects in Settings.
- Move these fields out of `/settings/workflow`:
  - `tracker_project_slug`,
  - `project_repository_url`,
  - `project_default_branch`.
- Keep shared workflow fields in `/settings/workflow`:
  - assignee,
  - active states,
  - terminal states,
  - checkout depth,
  - setup/cleanup commands,
  - hooks,
  - workspace/runtime/codex,
  - workflow phase/routing fields.
- Ensure runtime workflow generation uses the selected/current project-specific values when building the complete active workflow package.
- Ensure version history remains semantically correct after the split.

## Non-Goals

- Do not split per-project active workflow versions in this plan unless absolutely required to make runtime correct.
- Do not add per-project agent profiles; agent settings remain shared.
- Do not add per-project hooks/setup commands; these remain shared for now.
- Do not design Linear team discovery or project search in this plan.
- Do not preserve confusing duplicate edit paths for the same fields.

## Design Decisions To Validate During Implementation

- The canonical source for Linear project slug should be project settings, not the Workflow form.
- The canonical source for repository URL/default branch should be project settings, not the Workflow form.
- The default project can be auto-created for empty databases, but it must be editable in Settings.
- If multiple projects exist, the UI must make the active/default project behavior explicit before runtime starts listening.
- Shared workflow saves should compose with the selected/default project values when producing the active runtime workflow package.

## Acceptance Criteria

- [x] Settings has a Projects tab/page for project configuration.
- [x] The standalone Projects nav/page is removed or clearly demoted according to the chosen route policy.
- [x] Multiple projects can be listed from Settings.
- [x] A project can be created with name, slug, Linear project slug, repository URL, default branch, and enabled flag.
- [x] A project can be edited and persisted.
- [x] `/settings/workflow` no longer shows Linear project slug, repository URL, or default branch fields.
- [x] `/settings/workflow` still shows shared workflow settings.
- [x] Workflow save composes shared workflow settings with the current project-specific slug/repository/default branch.
- [x] Agents settings remain shared and unaffected by project selection.
- [x] Runtime validation still fails clearly when the selected/default project lacks repository URL or Linear project slug.
- [x] Tests cover multiple projects and shared-vs-project-specific boundaries.
- [x] Docs explain that projects are configured under Settings and which fields are project-specific versus shared.

## Test Plan

- Add persistence tests for project create/update fields and list ordering.
- Add LiveView tests for `/settings/projects`:
  - empty/default project state,
  - multiple project list,
  - create project,
  - edit project,
  - validation errors.
- Update existing `/settings/workflow` tests to assert project-specific fields are absent.
- Add a save/composition test proving workflow output uses project-specific repository URL/default branch/Linear project slug while shared fields come from Workflow settings.
- Update navigation tests/docs for removing or demoting `/projects`.
- Run:
  - `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Prefer a migration that adds project-owned fields to `projects` if the project record is the intended source of truth:
  - `linear_project_slug`
  - `repository_url`
  - `default_branch`
- If `tracker_configs` remains the canonical place for Linear project slug, the project settings UI must edit that record transparently and clearly. Avoid showing the same slug in both Projects and Workflow.
- Add persistence functions such as `update_project/2` and possibly `default_project_settings/0` rather than making LiveView build raw Ecto changesets directly.
- Fake persistence must support the new project CRUD boundary so tests keep using mock inputs instead of runtime fixture files.
- Be careful with existing dirty worktree state; this plan should not revert prior settings/history changes.
