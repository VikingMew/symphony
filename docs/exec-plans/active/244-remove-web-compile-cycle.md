# 244 Remove the Web compile-connected cycle

## Goal

Make `Endpoint` depend only on `Router`; stop LiveViews/Controllers from calling back into
`Endpoint.config/1`; dedupe the shared orchestrator/timeout resolution.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md M4. `Endpoint` compiles `Router` (endpoint.ex:32); Router references
LiveViews/Controllers; those consumers call `Endpoint.config/1` back
(dashboard_live.ex:528-544, admin_live.ex:167-169, observability_api_controller.ex:56-62).
Orchestrator/timeout resolution is duplicated in Dashboard and the API controller. xref reports a
length-6 cycle containing 1 compile edge. Violates Linus "remove complexity" (unclear dependency
direction, duplicated helper) and Carmack "hard to make simple is still worth it".

## Scope

- One narrow Web runtime accessor (or mount/conn injection) providing the orchestrator name and
  timeout; `Endpoint` stops being the back-channel.
- Dashboard, AdminLive, ObservabilityApiController consume the accessor; delete the duplicated
  resolution.
- Preserve test injection of custom orchestrator/timeout.

## Out of Scope

- General service locator / DI framework; touching Endpoint's plug pipeline beyond the Router
  dependency.

## Acceptance Criteria

- `mix xref graph --format cycles` no longer reports the length-6 Endpoint/Router/... cycle
  (compile edge gone).
- Web suites (dashboard, admin, observability API) green with custom orchestrator/timeout.

## Test Cases

- Existing web tests (they already inject custom orchestrator/timeout — must stay green).
- xref cycle check.

## Implementation Notes

Keep the accessor tiny (two keys, three consumers) — per the report, this small boundary earns its
cost; do not grow it into a registry.

## Dependencies

- None.

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

