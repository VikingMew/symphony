# 239 Typed errors for DB reads (no fake setup-required / empty data)

## Goal

Make database faults visible at every read EXIT: no `{:ok, workflow}` when the store is in an error
state, no setup-required facade on a real fault, no analytics/runs UI that shows "zero data" when
the DB is down.

## Status

Completed.

## Background

Source: REFACTOR_REVIEW.md H1. Plan 229 fixed the SOURCE (load/reload/startup paths reraise,
last-known-good retained), but error honesty still leaks at the exits:
- `WorkflowStore.current/0` (workflow_store.ex:30-33) is spec'd `{:ok, loaded_workflow}` and always
  returns ok — the `{:error, reason}` state from load is swallowed; `Config.settings/0`
  (config.ex:24-32) therefore only ever sees `:setup_required`.
- `state_payload/1` (workflow_store.ex:280-306) fills `Workflow.setup_required_workflow/1` when no
  workflow exists, so a genuine DB fault renders as "open /settings/workflow to create one".
- Persistence read APIs (persistence.ex:101-124, 147-203) return `nil` / `[]` / empty pages when
  the repo is unavailable; `analytics.ex:89-110` (`safe_list_runs/events/projects`) catch-all
  `rescue _ -> []` turns every fault into zeros; admin_live/runs.ex:19-20 renders
  "No persisted runs yet".

## Scope

- `WorkflowStore.current/0` / `current_with_source/0`: return a typed sum type
  (`{:ok, workflow}` | `{:error, :no_active_workflow | :repo_unavailable | {:query_failed, reason}}`);
  keep last-known-good on reload (229 behavior unchanged).
- `Config.settings/0` and `state_payload/1`: propagate/distinguish the error state instead of
  synthesizing setup-required; a truly empty DB still yields setup-required (no regression).
- Persistence read APIs (list_runs / list_events / list_projects / pages): typed `{:error, reason}`
  on repo-unavailable/query failure instead of `nil`/`[]`.
- `analytics.ex`: replace catch-all `rescue -> []` with explicit error surfacing ("数据不可用"
  state in UI payloads), keep empty-data semantics for genuinely empty stores.
- `admin_live/runs.ex` and dashboard surfaces: render a distinct "unavailable" state, not
  "no persisted runs yet" / zero metrics.

## Out of Scope

- Retry/backoff redesign; offline caching; changing the reload last-known-good policy.
- WorkerQueue/WorkflowStore internal-boundary work (that is plan 247, sequenced after this one).

## Acceptance Criteria

- With the repo down (stubbed persistence raising): dashboard/analytics/runs show an explicit
  unavailable state; `Config.settings/0` never reports setup-required for a fault.
- With a genuinely empty DB: setup-required still returned (no regression).
- With the DB healthy: all current values identical.

## Test Cases

- Stubbed-persistence fault per exit: current/0, settings/0, list_runs, list_events,
  list_projects, analytics payloads.
- Empty-DB no-regression test.
- Existing workflow_store/orchestrator/analytics suites stay green.

## Implementation Notes

Migration is caller-wide; do it in one exec plan with a typed-contract pass per layer
(WorkflowStore -> Config -> Persistence reads -> Analytics -> Web surfaces). Pair with plan 247's
internal-boundary cleanup only AFTER this contract lands.

## Dependencies

- Plan 229 (source honesty, already complete) is the foundation; this plan completes the exits.
- Plan 247 follows this one (Persistence internal boundaries on top of the new typed contract).

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 22 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 701 tests, 1 failure (full suite). The single failure is the PRE-EXISTING
  CoreTest "run-start persistence failure" cross-file race (documented in plans 233/235/236/237/238,
  identical to the plan-232 control run); NOT introduced by this plan. Isolated runs green:
  core + workflow_store + read_errors = 47 tests, 0 failures.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (workflow_store.ex, config.ex, persistence.ex,
  persistence_provider.ex, analytics.ex, run_history.ex, orchestrator.ex call sites, web
  surfaces, tests; lib/symphony_elixir/persistence/workflow_store.ex untouched — plan 247's
  territory)

## Completion Deviations

- `WorkflowStore.current/0` / `current_with_source/0` now return the typed sum
  `{:ok, ...} | {:error, :no_active_workflow | :repo_unavailable | {:query_failed, term()}}`;
  last-known-good reload (plan 229) behavior unchanged.
- `Config.settings/0`: `{:error, :no_active_workflow}` maps to `{:error, :setup_required}`
  (empty DB no-regression); other errors propagate. New `runtime_unavailable_message/1` renders
  repo_unavailable/query_failed for web surfaces; `settings!/0` still raises on error.
- `PersistenceProvider.read/1`: ONE narrow read guard converting raised exceptions/catches into
  `{:error, {:query_failed, ...}}`; typed `read_error` type.
- `Persistence` read APIs (`list_runs`, `list_runs_for_issue`, `list_events`, `list_projects`,
  page variants) return `{:error, read_error()}` instead of nil/[] on faults; spec'd and
  migrated all callers (orchestrator, run_history, analytics, web).
- `Analytics.summary/1` returns `summary() | unavailable_summary()` with `status: :available |
  :unavailable`; catch-all rescue/catch removed. Web (analytics_live, runs, run_detail,
  issue_detail, events, workers, presenter) renders an explicit "Data unavailable" state; the
  "No persisted runs yet"/zero-metric fallbacks are no longer reachable on faults.
- New test file persistence/read_errors_test.exs (repo-down + raising-query typed errors) plus
  per-surface unavailable-state tests. Test baseline 692 -> 701 (+9).

## Dependencies

