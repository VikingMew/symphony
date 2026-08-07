# 154 - Linear Diagnostics Probe Boundary

Status: Completed

## Problem

`SymphonyElixir.Linear.Diagnostics` owns runtime workflow resolution, setup-required messaging, token diagnostics, individual Linear probes, project/team/issue normalization, diagnostics log shaping, and log emission.

The probe execution and probe result normalization are a coherent slice that can be tested without the full diagnostics runner and logging path.

## Goal

Extract Linear diagnostics probes into a focused boundary such as `SymphonyElixir.Linear.Diagnostics.Probes`.

The top-level diagnostics module should orchestrate context loading and final result/logging; probe modules should own API calls and probe result data.

## Plan

1. Inventory probe helpers: API, teams, project, states, candidates, missing token/project slug handling, and result normalization.
2. Move probe execution and project/team/issue normalization into a probe module.
3. Keep runtime workflow/context resolution in `Linear.Diagnostics`.
4. Keep final diagnostics log formatting either in `Linear.Diagnostics` or extract it separately only if needed.
5. Add focused tests for each probe status, skipped dependencies, project/team state extraction, candidate details, and sanitized GraphQL errors.
6. Coordinate with plan 138 so health classification consumes normalized probe output rather than duplicating status rules.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_probes_test.exs test/symphony_elixir/linear_diagnostics_test.exs test/symphony_elixir/linear_health_test.exs` - 29 tests, 0 failures
- `rg -n "api_probe|teams_probe|project_probe|states_probe|candidate_probe|normalize_project|normalize_team|normalize_issue|probe\\(" lib test`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- Missing token and missing project slug gating remain in `Linear.Diagnostics` because they depend on runtime configuration context; the probe module owns API-backed probe execution and normalization.
