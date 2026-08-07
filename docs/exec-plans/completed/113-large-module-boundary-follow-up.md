# 113 Large Module Boundary Follow-up

Status: Completed

## Goal

Turn the broad large-module debt left by plan 105 into concrete, incremental extraction slices without pretending the first helper extraction closed the whole module-boundary problem.

## Background

Plan 105 extracted `RunHistory` and `RunLifecycle`, but explicitly left broader decomposition for later. Current large modules still include `AdminLive`, `Orchestrator`, `Codex.AppServer`, and `Workspace`. Plan 111 identified that debt as still active.

## Scope

- Re-read the current responsibilities of:
  - `lib/symphony_elixir_web/live/admin_live.ex`
  - `lib/symphony_elixir/orchestrator.ex`
  - `lib/symphony_elixir/codex/app_server.ex`
  - `lib/symphony_elixir/workspace.ex`
- Define the next 2-4 extraction candidates with clear ownership and tests.
- Implement only low-risk extractions that reduce coupling without changing runtime behavior.
- Create additional execplans if the audit finds a larger refactor that should not be bundled.

## Out of Scope

- Rewriting the LiveView settings architecture.
- Replacing the orchestrator process model.
- Changing Codex protocol behavior.
- Changing workspace directory layout.

## Acceptance Criteria

- Each extracted boundary has a single named owner module and focused tests.
- `AdminLive`, `Orchestrator`, `Codex.AppServer`, or `Workspace` loses at least one coherent responsibility if implementation proceeds in this plan.
- If implementation is deferred, the plan must produce narrower active execplans for the concrete slices instead of staying as a vague debt note.
- No behavior changes without tests that describe the old and new behavior.

## Test Cases

- Module-specific unit tests for extracted logic.
- Existing LiveView, orchestrator, app-server, and workspace regression tests relevant to touched paths.
- `mix lint`
- `mix test --cover`

## Implementation Notes

- Prefer pure helper/service extraction over process-boundary rewrites.
- Keep public function surfaces small.
- Move tests alongside the extracted module rather than relying only on end-to-end coverage.

## Verification

- Re-read large module boundaries and selected a low-risk extraction that reduces presentation responsibility without changing process or protocol behavior.
- Added `SymphonyElixir.NumberFormat` as the owner for grouped integer presentation.
- Removed grouped-number formatting helpers from `StatusDashboard`; token usage summaries now call `NumberFormat`.
- Added focused unit coverage for the extracted module.
- `mix format --check-formatted`
- `mix lint`
- `mix test --cover`

## Completion Deviations

- This plan intentionally implemented one small boundary extraction rather than attempting broad AdminLive/Orchestrator/AppServer/Workspace decomposition in the same change. Larger extraction candidates should be planned separately when they have a concrete behavior boundary and test strategy.

## Dependencies

- Plan 105.
- Plan 111.

## Handoff Notes

Do not treat line count alone as the problem. Extract responsibilities only where the boundary is already visible in current behavior.
