# 253 Persistence upsert_issue / create_run require explicit project_id

## Goal

Fix the regression left by plan 250: `Persistence.upsert_issue/1` and `Persistence.create_run/1`
still resolved the project via `default_project()` and silently attached its id with
`Map.put_new`. With plan 250/252 the default project no longer exists on multi-project
installations (and 252 deleted the leftover row), so both functions returned
`{:error, :not_found}` for every call — the operator task (nap) failed with
"run-start persistence failed: {:create_operator_run, :not_found}" as soon as a nap was
requested from the dashboard.

The fix makes both functions require an explicit `project_id` in attrs (matching the plan-250
`WorkerQueue.enqueue_task` treatment): missing/blank → `{:error, :project_id_required}`. All
call sites (orchestrator) already pass `project_id` explicitly.

## Status

Completed.

## Background

- plan 250 changed `WorkerQueue.enqueue_task` to require explicit project_id, but missed the
  sibling persistence functions `upsert_issue` and `create_run` (persistence.ex:90-108), which
  still did `{:ok, project} <- default_project()` then `Map.put_new(:project_id, project.id)`.
- After plan 252 deleted the `slug=default` row, `default_project()` returns
  `{:error, :not_found}` on this install → `create_run` short-circuits with that error even
  though attrs already carried a valid `project_id`.
- All production callers already pass project_id: `persist_issue_run_started` (2802-2809),
  `upsert_issue!/2` (2822-2824), `create_operator_run!/2` (2858-2869), worker paths
  (2879, 2889). No caller relied on the implicit default.

## Scope

- `persistence.ex`: `upsert_issue/1` and `create_run/1` use a new private
  `required_project_id/1` (identical shape to the plan-250 worker_queue helper): binary,
  non-empty `attrs[:project_id]` → `{:ok, id}`; else `{:error, :project_id_required}`.
  Remove the `default_project()` dependency from both functions.
- Tests: project_test gains two cases asserting `:project_id_required` for missing/blank
  project_id on both functions.

## Out of Scope

- Removing `default_project/0` from the public API (separate cleanup if desired).
- Changing orchestrator call sites (they already pass project_id).

## Acceptance Criteria

- `Persistence.create_run(%{})` / `%{project_id: ""}` → `{:error, :project_id_required}`.
- `Persistence.upsert_issue(%{identifier: ...})` without project_id →
  `{:error, :project_id_required}`.
- Operator task (nap) run persistence works with explicit project_id on a multi-project
  install with no default row.
- format/compile/specs pass; targeted tests green.

## Completion Deviations

No deviations from the plan as written.

All acceptance criteria met:

- `Persistence.create_run(%{})` / `%{project_id: ""}` → `{:error, :project_id_required}`;
  with valid project_id the function proceeds (orchestrator operator-task path verified via
  existing tests).
- `Persistence.upsert_issue(%{identifier: ...})` without project_id →
  `{:error, :project_id_required}`.
- All production callers already passed project_id; no caller relied on the implicit default.
- format/compile/specs pass; targeted tests green (project_test x5, settings live x1,
  operator-tasks + settings-fake x50).
- Direct fix by orchestrator (not Codex): plan 253 was authored and implemented in one pass
  after the dashboard nap failure was reported; commit b69f07d (see repo log).
