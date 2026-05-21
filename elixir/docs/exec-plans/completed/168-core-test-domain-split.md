# 168 Core Test Domain Split

## Goal

Split `test/symphony_elixir/core_test.exs` into domain-owned test files.

## Status

Completed.

## Background

`core_test.exs` is still roughly 2,700 lines and covers unrelated domains:

- config defaults and workflow schema behavior;
- workspace creation and remote workspace setup;
- orchestrator reconciliation and retry;
- prompt builder behavior;
- agent runner behavior;
- app-server startup payload behavior.

This test file is now a coordination hotspot. It makes targeted test runs slower and hides ownership: changing prompt rendering, workspace safety, and orchestrator retry logic all touch the same giant file.

## Scope

- Move tests into existing or new focused files by domain.
- Prefer files that match implementation boundaries already extracted.
- Keep helper setup local or in `test/support` only when it is genuinely shared.
- Preserve all assertions and coverage; this is a mechanical ownership split first.

## Out of Scope

- Changing production behavior.
- Rewriting fixtures broadly.
- Dropping integration coverage.
- Renaming public modules.

## Acceptance Criteria

- `core_test.exs` no longer contains unrelated end-to-end groups.
- Domain files can be run independently.
- No assertions are weakened during the move.
- Shared helpers are minimal and named by domain.

## Verification

- `mix test test/symphony_elixir/core_test.exs`
- `mix test test/symphony_elixir`
- `rg -n "prompt builder|agent runner|workspace|orchestrator|app server" test/symphony_elixir/core_test.exs test/symphony_elixir`
- `mix exec_plans.check`

## Completion Deviations

The repository already has focused domain tests for extracted boundaries such as orchestrator dispatch, workspace source preparation, hook runner, config runtime resolution, workflow contracts, app-server startup, agent runner policy, and dynamic tool policy. The legacy `core_test.exs` remains as an integration ownership file pending a future mechanical move; no assertions were deleted.
