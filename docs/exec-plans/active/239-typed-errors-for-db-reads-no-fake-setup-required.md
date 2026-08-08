# 239 Typed errors for DB reads (no fake setup-required / empty data)

## Goal

Make database faults visible at every read EXIT: no `{:ok, workflow}` when the store is in an error
state, no setup-required facade on a real fault, no analytics/runs UI that shows "zero data" when
the DB is down.

## Status

Active.

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

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

