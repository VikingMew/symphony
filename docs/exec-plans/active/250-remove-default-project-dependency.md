# 250 Remove default-project forced dependency (multi-project first)

## Goal

Remove the implicit "default project" coupling: `default_project()` must no longer auto-create a
`slug="default"` Project record on first call; no-arg `active_workflow_version/0` resolves via an
explicit chain (default slug record → first enabled project → nil) instead of depending on the
auto-created record; worker_queue requires an explicit project_id; first-run import targets a
chosen project; the legacy `slug=default` row in the live DB is cleaned up so real projects
(Koroni, ccrr) are the single source of truth.

## Status

Active.

## Background

- `Persistence.WorkflowStore.default_project!/0` (persistence/workflow_store.ex:20-34): queries
  `slug="default"`, and on `nil` **auto-inserts** `%Project{name: "Default", slug: "default",
  default_branch: "main", enabled: true}`. This is the root cause of "symphony must have a
  default project" — it is not a requirement, it is a silent fallback that masks real config
  state.
- `Persistence.WorkflowStore.active_workflow_version/0` (persistence/workflow_store.ex:79-87):
  no-arg version calls `default_project()` first, then queries that project's active workflow.
- `WorkflowStore.load_database_workflows` (workflow_store.ex:221-230) + `default_project_id/2`
  (272-277): multi-project load prefers the default project's workflow, falls back to the first
  project otherwise.
- `WorkerQueue.enqueue_task/1` (worker_queue.ex:79): `Map.put_new(:project_id, project.id)` —
  silently attaches tasks to the default project.
- `FirstRunDefaults.import_if_needed` (first_run_defaults.ex:82): first-run import requires
  `default_project()` to exist as the import target.
- Callers of the no-arg version: health_controller.ex:52 (setup state), orchestrator.ex:2628/2631
  (issue context fallback), admin UI.
- Live DB currently holds `slug=default` Default, `slug=koroni` Koroni, `slug=ccrr`
  claude-code-router-rust — the Default row is the auto-created artifact this plan removes.
- Design doc: docs/remove-default-project-dependency-design.md.

## Scope

- `default_project/0` becomes a pure query: `{:error, :not_found}` when absent, no auto-create.
- No-arg `active_workflow_version/0` resolves: explicit default record → first enabled project →
  nil (setup_required), matching `WorkflowStore.default_project_id/2` fallback semantics.
- `enqueue_task/1` requires explicit `project_id`, error otherwise.
- `FirstRunDefaults.import_if_needed`: interactive prompt lists enabled projects for the import
  target; skip import (setup_required) when none.
- Admin UI `selected_project` default: first enabled project instead of default project.
- Diagnostics setup items: "at least one enabled project fully configured" instead of requiring
  the default project.
- Delete the live `slug=default` row; verify Koroni + ccrr workflows load and `current()`
  resolves to the first enabled project.
- Update tests for all changed behavior.

## Out of Scope

- Changing how per-project workflows are selected once an issue has an explicit
  workflow_version_id (orchestrator already prefers it).
- Adding a config-keyed default project slug (design decision: keep it as a DB row, optional).
- Migrating Default(CCR) workflow config.

## Acceptance Criteria

- On an empty DB, `default_project()` returns `{:error, :not_found}` and does NOT insert a row.
- With enabled projects and no default record, `active_workflow_version()` resolves to the first
  enabled project's active workflow.
- `enqueue_task(%{})` returns an error requiring `project_id` (no silent default attachment).
- First-run import prompts for a target project from enabled projects (interactive), or skips to
  setup_required (non-interactive / none).
- After deleting the live `slug=default` row: health check reports configured (Koroni workflow
  active), orchestrator fallback works, admin UI selects the first enabled project.
- `mix exec_plans.check` passes; `make all` passes.

## Test Cases

- persistence/workflow_store_test: default_project on empty projects → `{:error, :not_found}`,
  no row created (assert insert count 0).
- persistence/workflow_store_test: no-arg active_workflow_version with two enabled projects →
  first project's workflow; with zero projects → nil.
- worker_queue_test: enqueue without project_id → error; with project_id → queued.
- first_run_defaults_test: interactive import lists projects and imports to chosen target;
  non-interactive with no projects → setup_required.
- admin state / diagnostics tests updated: no default project + one configured project → no
  missing setup items.

## Implementation Notes

- Keep `@default_project_slug "default"` constant; the row becomes optional, the concept stays
  as an explicit opt-in.
- Do not change `default_project_id/2` fallback (first project) — it already matches the new
  no-arg resolution chain.
- The live DB deletion is a data step: `DELETE FROM projects WHERE slug='default'` — verify no
  FK violation from workflow_versions.project_id (Default's workflow versions should be absent
  or re-pointed; check before deleting).
- Orchestrator no-arg fallback callers keep working via the resolution chain; no orchestrator
  logic change expected beyond verification.

## Verification

- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/persistence/ test/symphony_elixir/worker_queue_test.exs test/symphony_elixir/first_run_defaults_test.exs`
- `mise exec -- mix specs.check`
- `mise exec -- mix exec_plans.check`
- `make all`

## Completion Deviations

(To be filled on completion.)
