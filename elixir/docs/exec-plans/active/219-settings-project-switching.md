# 219 Settings Project Switching & Final Multi-Project Sweep

## Goal

Make the Settings surface project-aware: operators can select which project they are editing
(workflow versions, agent settings, hooks), the settings forms and version history read and
write that project's records, and the final documentation sweep from plan 215 is completed so
the repository's written intent matches the multi-project runtime after plans 216-218.

## Status

Active.

## Background

Plans 216-218 made the runtime store, orchestrator dispatch, and observability lists
multi-project. Settings still edits the default project only: `AdminLive` (which `SettingsLive`
delegates to) loads `active_workflow_version/0`, `default_project/0`, and
`persistence().default_project()` throughout the workflow/agents/runtime forms, and the version
history lists every project's versions without a project scope. The settings tabs themselves
already exist (`/settings/projects`, `/settings/workflow`, `/settings/agents`,
`/settings/runtime`, `/settings/import`); this plan adds project selection chrome and threads
the selected project through the settings data paths, then finishes the plan-215 doc sweep.

## Scope

- Settings project selection:
  - Add a project switcher to the Settings header (reuse `Layouts.project_switcher/1` from
    plan 218, base path `/settings/workflow` or the current tab path) so the `project` query
    parameter selects the project being edited.
  - Thread the selected project through `AdminLive` settings data paths:
    - `refresh/1`: load the selected project's active workflow version (`active_workflow_version/1`
      from plan 216), `workflow_form/2` uses it, `workflow_versions` list is filtered to the
      selected project, and the `projects` tab keeps listing all projects for enable/disable
      editing.
    - `save_workflow_form` / `safe_import_workflow`: import/save against the selected project
      instead of `default_project()`.
    - `restore_settings_version`: restore a version belonging to the selected project.
    - `maybe_update_project`: unchanged (projects tab edits project records directly, no
      selection needed).
  - The projects tab keeps its "all projects" list; the switcher only scopes the workflow,
    agents, runtime, and import tabs.
  - With no `project` param, keep current behavior (default project) for compatibility.
- Documentation final sweep (completing plan 215):
  - `elixir/docs/documentation_alignment.md` rows: Settings ownership (per-project
    `/settings/workflow`, project selection is Settings chrome), observability rows (project
    filters on Runs/Events/Workers), Linear integration (one user, multiple slugs).
  - `elixir/docs/long_term_direction.zh-CN.md` 5.1 projects / Settings evolution sections.
  - `elixir/docs/user_guide.zh-CN.md` Settings and observability sections (project switching +
    filtering).
  - Root `README.md` and `elixir/README.md` project-aware Settings claims that were deferred
    from 218.
  - Verify `SPEC.md` / `ARCHITECTURE.md` / `CODE_STRUCTURE*.md` claims already landed with
    216/217; fix any drift.
- Quality gates: run `make all` for the first time at the end of the 217-219 sequence
  (format, lint, coverage >= 85%, dialyzer) and record the outcome.

## Out of Scope

- Per-project settings records for profiles (profile semantics stay shared; plan 215 section C).
- Per-project concurrency policy changes.
- Analytics/dashboard per-project analytics (deferred in 218; revisit only if asked).
- The pre-existing missing `@spec` declarations (plan 220).

## Acceptance Criteria

- With two enabled projects, `/settings/workflow?project=<id>` loads, validates, and saves
  workflow settings for that project; the default project's version is untouched.
- Version history on the workflow/agents tabs shows only the selected project's versions.
- The Settings header renders a project switcher; switching preserves the current tab and
  reloads the forms for the new project.
- No `project` param behaves exactly as before (default project editing).
- `documentation_alignment.md`, `long_term_direction.zh-CN.md`, `user_guide.zh-CN.md`, root
  `README.md`, and `elixir/README.md` no longer contain single-project Settings claims.
- `make all` passes (or the deviations record exactly which gate and why).

## Test Cases

- Settings project switch test (fake persistence):
  - seed two projects each with a distinct active workflow version;
  - assert `/settings/workflow?project=<id>` renders the selected project's version fields and
    version history contains only that project's versions;
  - save edits with `?project=<id>` and assert the other project's version is unchanged.
- No-param regression: `/settings/workflow` renders the default project's version.
- Projects tab regression: all projects still listed, enable/disable still works.
- Switcher render: settings header includes options for all projects with the current one
  selected and preserves the tab path.
- Documentation check: grep each swept file for stale single-project Settings claims.

## Implementation Notes

- `project_filter/1` already exists in `AdminLive` (plan 218); reuse it for the settings
  tabs. The `settings_tabs/1` component and tab links need to preserve an existing `project`
  query param when switching tabs (build links via `settings_tab_path/1` + `?project=` when
  one is active).
- `workflow_form/2` currently receives `active_workflow_version/0`; change `refresh/1` to
  resolve the selected project's version: `persistence().active_workflow_version(project)` when
  a project is selected and a project record is found, falling back to the current behavior.
- `safe_import_workflow/3` already takes a project; pass the selected project. The workflow
  save path uses `default_project()` today — replace with the selected project, falling back to
  default when unset.
- Version restore: `restore_settings_version` reads `version.id` from the event; the version
  row carries `project_id`, so restoring against the selected project is mostly validation —
  guard that the version belongs to the selected project when one is selected.
- Keep `@spec` on new public functions; settings helpers stay `defp`.
- The doc sweep is a review pass: run `mix exec_plans.check` and `make all` after it.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test` (new settings-switch tests + full suite regression)
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `make all` (first run at the end of the 217-219 sequence; record coverage/dialyzer results).

## Completion Deviations

- To be filled after implementation.

## Dependencies

- Plan 218 (shared `Layouts.project_switcher/1`, `project_filter/1`, observability filtering).
- Plan 216 (per-project `active_workflow_version/1`, per-project workflow versions).
- Plan 215 (documentation inventory; this plan finishes its sweep).

## Handoff Notes

The subtle part is that `SettingsLive` delegates everything to `AdminLive`, so all settings
data paths live in one module — do not add project switching to `SettingsLive` itself. Keep the
"no param = default project" fallback so single-project installs never notice the change. When
saving, verify against the other project's version in the test, not just the selected one, to
prove isolation.
