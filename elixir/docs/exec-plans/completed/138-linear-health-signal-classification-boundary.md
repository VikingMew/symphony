# 138 - Linear Health Signal Classification Boundary

Status: Completed

## Problem

Linear health now has a shared `Linear.Health` module, but status classification and presentation fallback logic still exists in more than one place.

The duplicated rules include:

- probe status aggregation,
- primary probe selection,
- primary detail formatting,
- default project slug fallback,
- conversion from diagnostics health into dashboard signal state.

`Linear.Health.latest/0` stores a normalized health summary, while `LinearStatusSignal.from_health/1` and related presenter paths still reclassify parts of the same state. This is a bad boundary: health collection and UI signal formatting can drift again, and tests have to cover duplicated behavior rather than a single contract.

## Goal

Make Linear health classification a single owned boundary:

- `Linear.Health` owns probe aggregation and normalized health state.
- UI/presenter modules consume normalized state and format it, without duplicating classification decisions.
- The default project slug/status fallback is resolved once per health snapshot.

## Plan

1. Inventory every function that derives Linear status from probe lists or diagnostics health, especially in `Linear.Health`, `LinearStatusSignal`, `Presenter`, and Linear diagnostics LiveView paths.
2. Define a compact normalized health struct/map shape that includes status, label/detail, selected primary probe, default project availability, and timestamp.
3. Move classification helpers into `Linear.Health` or a small pure submodule owned by it.
4. Reduce `LinearStatusSignal` to presentation-only conversion from normalized health into dashboard signal fields.
5. Update dashboard and diagnostics tests to assert the normalized health contract once, then assert UI formatting separately.
6. Remove duplicate private helper implementations after call sites use the shared boundary.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/linear_health_test.exs test/symphony_elixir/linear_diagnostics_test.exs test/symphony_elixir/dashboard_signal_test.exs`
  - `29 tests, 0 failures`
- `rg -n "status_from_probe_statuses|primary_probe|primary_detail|default_project_slug|from_health|display_status|health_detail" lib test`
  - Probe status aggregation, primary probe selection, primary detail formatting, default project fallback, and display status derivation now live in `SymphonyElixir.Linear.Health`.
  - `SymphonyElixirWeb.LinearStatusSignal` consumes normalized `display_status`, `label`, and `display_detail` values instead of reclassifying health.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
