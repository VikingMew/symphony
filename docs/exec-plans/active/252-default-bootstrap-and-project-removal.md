# 252 Default project bootstrap on empty DB + manual project removal

## Goal

Restore first-boot guidance without reintroducing the "global default" coupling: `default_project!`
auto-creates a `slug="default"` bootstrap project ONLY when the projects table is empty (fresh
install), and never otherwise. Users remove projects (including any leftover default) manually
through a new "Remove project" button in Settings/Projects — no automatic cleanup magic.

## Status

Active.

## Background

- Plan 250 (merged 2f95837) made `default_project!` a pure query: absent row → `{:error,
  :not_found}`, no auto-create. Regression: a fresh install (zero projects) now lands directly in
  setup-required with no bootstrap — the operator must hand-create a project in Settings before
  anything runs.
- User's intended semantics: default is a *bootstrap anchor for an empty DB*, not a *global
  default*. First boot (zero projects) → auto-create it and import default workflow.yml. Once any
  real project exists (koroni / ccrr) → default must not exist, not be referenced, not be
  resolved. Removal is an explicit user action (button), NOT automatic cleanup.
- FK topology: `workflow_versions.project_id` → CASCADE on delete; `runs.project_id`,
  `issues.project_id`, `tasks.project_id` → NO ACTION (must be handled explicitly).
- Settings/Projects UI currently supports edit + create only; no delete. Persistence layer has no
  `delete_project/1`.

## Scope

1. **Conditional bootstrap creation**: `default_project!` (persistence/workflow_store.ex)
   becomes: when `repo_available?()`, list projects; if **zero** projects → insert
   `%Project{name: "Default", slug: "default", default_branch: "main", enabled: true}` and return
   it; if projects exist (any) → `{:error, :not_found}`. Never auto-create when ≥1 project exists.
   Remove the old unconditional auto-create path and its now-dead branch.
2. **First-run import wiring**: ensure the first-run defaults flow still imports
   workflow.yml/profiles.yml for the freshly created bootstrap project (interactive prompt may
   offer it; non-interactive may log). Verify `first_run_defaults` behavior for the zero-project →
   auto-create → import path; adjust logging/messages if the current "start in setup-required
   mode" branch is now unreachable for the empty-DB case.
3. **`Persistence.delete_project/1`**:
   - Deletes the project row (workflow_versions cascade automatically).
   - Explicitly sets `project_id = NULL` on runs / issues / tasks rows referencing it (keep audit
     history, detach ownership).
   - Returns `{:ok, deleted_project}` or `{:error, reason}` (e.g. repo unavailable).
   - Must be safe when called for the last project (leaves DB empty → next boot re-bootstraps).
4. **Settings/Projects remove button**:
   - Each project card gains a "Remove" button (phx-click + data-confirm).
   - `handle_event("remove_project", %{"project_id" => id}, socket)` calls
     `Persistence.delete_project/1`, then refreshes; flash success/error.
   - Disable/navigate safety: removing the currently selected project should fall back to the
     first remaining enabled project (reuse existing `selected_project/2` logic); removing the
     last project leaves the list empty (fresh-boot state, acceptable and visible).
5. **Tests**:
   - `default_project!`: zero projects → creates + returns; ≥1 project → `:not_found`, no insert.
   - first-run: zero-project boot imports into the auto-created bootstrap project.
   - `delete_project/1`: cascades workflow_versions, nulls runs/issues/tasks, deletes row.
   - Settings/Projects: remove button event calls delete and refreshes; removing selected project
     falls back to first enabled.

## Out of Scope

- Automatic cleanup of a leftover `slug="default"` row when real projects exist (explicit user
  removal only).
- Changing plan 250/251 project resolution (worker_queue / operator tasks / admin selected
  project stay explicit).
- Multi-project batch operations.
- Linear-side project deletion.

## Acceptance Criteria

- Fresh install (empty DB) boots with an auto-created Default project and imports default
  workflow — no manual project creation needed.
- Existing install (≥1 project) never sees a new default created; `default_project()` returns
  `{:error, :not_found}`.
- Settings/Projects shows a working Remove button per project; removing a project deletes it,
  cascades its workflows, detaches run/issue/task history (project_id NULL), and the UI
  refreshes correctly.
- Removing the last project is allowed and lands the system in fresh-boot state (next boot
  re-bootstraps).
- `mix exec_plans.check` passes; `make all` passes (lint 0 [F], no new warnings vs baseline;
  dialyzer baseline 6 pattern_match_cov unchanged or only coverage-class additions).

## Test Cases

- workflow_store_test: `default_project/0` with empty projects table → `{:ok, %Project{slug:
  "default"}}` and a row exists; with one existing project → `{:error, :not_found}` and no new
  row.
- first_run_defaults_test: zero-project + interactive → offers import for the auto-created
  bootstrap project; zero-project + non-interactive → logs and leaves bootstrap project.
- persistence_test (or project_test): `delete_project/1` with a project that has workflow
  versions / runs / issues / tasks → all workflow_versions gone, runs/issues/tasks project_id
  NULL, project row gone; with zero dependencies → row gone.
- settings_projects_live_test: `remove_project` event with project_id → delete called, flash
  success, list refreshed; removing currently-selected project → selected falls back to first
  remaining enabled.

## Implementation Notes

- The bootstrap-creation path must be race-safe under concurrent first boots (both processes
  see empty table). Use a unique constraint on projects.slug (check schema; if absent, either
  rely on SQLite serialization of the bootstrap call site or add the constraint + handle
  unique-violation as {:ok, existing}).
- `delete_project/1` must run in a transaction: delete project → update runs/issues/tasks SET
  project_id NULL. Order matters (null-out before/after delete both work with NO ACTION FK as
  long as no row references the deleted id at commit time).
- Keep the `@default_project_slug "default"` constant; the "default" name/slug only ever
  appears when the DB is empty.
- Do not remove `default_project/0` from the public API (plan 250 kept it; this plan changes its
  behavior only). Removing the concept entirely is a separate cleanup plan if desired.

## Verification

- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/persistence/workflow_store_test.exs test/symphony_elixir/first_run_defaults_test.exs test/symphony_elixir/persistence/project_test.exs test/symphony_elixir_web/live/settings_projects_live_test.exs`
- `mise exec -- mix specs.check`
- `mise exec -- mix exec_plans.check`
- `make all` (lint baseline compare; dialyzer baseline compare)

## Completion Deviations

(To be filled on completion.)
