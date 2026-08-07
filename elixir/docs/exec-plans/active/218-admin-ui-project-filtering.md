# 218 Admin UI Project Filtering

## Goal

Make the observability pages project-aware: `/runs`, `/events`, and `/workers` read an optional
`project` query parameter and filter their persisted rows by `project_id`, with a project
selector in the UI so operators can switch between enabled projects without losing the rest of
their filters.

## Status

Active.

## Background

Plans 216-217 made the runtime workflow source and orchestrator dispatch multi-project. Runs,
events, and worker tasks are now persisted with an originating `project_id`, but the admin UI
still lists everything across projects. This plan threads a `project_id` filter through the
LiveView list queries and surfaces a project switcher.

## Scope

- Backend list filters (already landed):
  - `SymphonyElixir.Persistence.list_runs/1`, `list_runs_page/1`: `project_id` filter via
    `maybe_filter_run_project/2`.
  - `SymphonyElixir.Persistence.list_events/1`: `project_id` filter via
    `maybe_filter_event_project/2`.
  - `SymphonyElixir.Persistence.WorkerQueue.list_tasks/1`: `project_id` filter via
    `maybe_filter_task_project/2`.
  - `test/support/fake_persistence.exs` mirrors all three filters.
- AdminLive (`lib/symphony_elixir_web/live/admin_live.ex`):
  - `event_filters/1` already reads the `project` query param into `project_id`.
  - `assign_runs_page/2` passes `project_id` to `list_runs_page/1`.
  - `event_list/1` passes `project_id` to `list_events/1`.
  - `refresh/1` tasks assignment passes `project_id` (assignment is unused by the template but
    kept consistent).
  - Runs page renders a project selector that links to `/runs?project=<id>` preserving the
    empty state.
  - Events filter form gains a Project select that submits `project=<id>` alongside the
    existing filters; quick links keep their current behavior.
- WorkersLive (`lib/symphony_elixir_web/live/workers_live.ex`):
  - `refresh/1` passes `project_id` to `list_tasks/1`.
  - Tasks section renders a project selector.
- Tests:
  - Runs page filtered by `?project=` shows only that project's runs.
  - Events page filtered by `?project=` shows only that project's events.
  - Workers tasks filtered by `?project=` shows only that project's tasks.
  - Unfiltered pages still show all rows (regression).
  - Fake persistence `list_runs_page/1`, `list_events/1`, `list_tasks/1` project filters.

## Out of Scope

- Dashboard (`DashboardLive`) and Analytics (`AnalyticsLive`) project filtering: both are
  status/summary surfaces driven by live state, not persisted row lists; they show
  project-level status already. Revisit if a follow-up asks for per-project analytics.
- Settings project switching (plan 219).
- Per-project event presenter summarization changes.

## Acceptance Criteria

- `/runs?project=<id>` lists only runs whose `project_id` equals `<id>`, including across
  pagination (`load_more_runs` keeps the filter).
- `/events?project=<id>` lists only that project's events, combined with the other filters.
- `/workers?project=<id>` lists only that project's worker tasks.
- The project selector renders the enabled projects with the current one selected and
  preserves the other query parameters.
- Without the `project` param, behavior is unchanged (all projects).
- `mix specs.check` shows no new missing specs; full test suite passes.

## Test Cases

- Runs filtered by project: seed two projects' runs, assert `/runs?project=<id>` shows only
  the matching ones and the unfiltered page shows both.
- Runs pagination keeps project filter: 30 runs for project A and 5 for project B, load more
  from A never shows B rows.
- Events filtered by project: seed events with `project_id`, assert filtered and unfiltered
  behavior.
- Events combined filters: `?project=<id>&severity=error` applies both.
- Workers tasks filtered by project: seed tasks with `project_id`, assert `/workers?project=<id>`
  shows only matching tasks.
- Project selector renders: with two projects seeded, the runs page includes a select with
  both options and the current project selected.

## Implementation Notes

- AdminLive reads the filter from `route_params["project"]` (already done in `event_filters/1`);
  reuse `blank_as_nil/1` so `?project=` and missing param behave the same.
- `assign_runs_page/2` currently builds `list_runs_page(page_size: ..., cursor: ...)`; add
  `project_id: project_filter(socket)` where `project_filter/1` extracts the param once.
- The runs page selector is a plain `<select onchange="location = this.value">` with option
  values being full URLs (`/runs` and `/runs?project=<id>`); the events selector is a
  `<select name="project">` inside the existing GET filter form so it submits with the rest.
- WorkersLive has no route-param plumbing today (`mount/3` ignores params); assign
  `route_params` in mount and read the same way AdminLive does.
- Keep `@spec` on all new public functions per AGENTS.md; helpers stay `defp`.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test` (new filtering tests + full suite regression)
- `mise exec -- mix lint`
- `mise exec -- mix specs.check`
- `mise exec -- mix exec_plans.check`
- `make all` at the end of the 217-219 sequence.

## Completion Deviations

- `project_switcher/1` lives in `SymphonyElixirWeb.Layouts` (shared component module) instead
  of AdminLive so both AdminLive and WorkersLive can render it without cross-module component
  imports. AdminLive keeps the events filter form's inline Project `<select>` (submits with the
  other filters), while the runs and workers pages use the switcher.
- WorkersLive `refresh/1` computes the project filter once into a `:project_filter` assign
  instead of calling a helper from the template; the helper needs a socket-shaped argument and
  the template only has route params.
- AdminLive's `@tasks` assign is not rendered by any template (task rows live on the workers
  page); it still receives the `project_id` filter for consistency.
- The runs page switcher uses `@event_filters.project_id` as its current value because
  `event_filters/1` already reads the `project` query param; no separate assign was added.
- `mix format` was also run on two files touched by plan 217 (`orchestrator.ex`,
  `orchestrator_multi_project_test.exs`) that had drifted out of format; no behavior change.
- `mix specs.check` still reports the same 5 pre-existing missing `@spec` declarations noted in
  plans 216/217; none are introduced by this plan.
- `mix format --check-formatted`, full `mix test` (658 tests, 0 failures), `mix exec_plans.check`
  pass. `mix lint` reports only the pre-existing specs.check failures; `make all` runs at the
  end of the 217-219 sequence.

## Dependencies

- Plan 217 (per-project persisted `project_id` on runs/events/tasks).
- Plan 216 (multi-project runtime workflow store).

## Handoff Notes

The backend filters and `event_filters/1` param reading were landed in the previous session;
what remains is the LiveView wiring (`assign_runs_page`, `event_list`, tasks assignment,
WorkersLive mount), the two selectors, and the tests. The subtle part is pagination: the
cursor is encoded from `inserted_at`/`id`, so as long as `project_id` is applied before the
cursor it composes correctly — do not filter the accumulated `@runs` list in the template.
