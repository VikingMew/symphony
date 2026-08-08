# 244 Remove the Web compile-connected cycle

## Goal

Make `Endpoint` depend only on `Router`; stop LiveViews/Controllers from calling back into
`Endpoint.config/1`; dedupe the shared orchestrator/timeout resolution.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix xref graph --format cycles` — PASS: `endpoint` no longer appears in ANY
  cycle (grep count 0); the length-6 (1 compile) Endpoint/Router/AdminLive/DashboardLive/
  SettingsLive/API cycle is GONE.
- `mise exec -- mix test` — 710 tests, 0 failures, 2 skipped (FULL SUITE GREEN)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (3 consumer modules + new
  lib/symphony_elixir_web/web_runtime.ex)
- grep acceptance: `Endpoint.config` consumers in lib/symphony_elixir_web/ -> zero hits outside
  the new accessor

## Completion Deviations

- New `SymphonyElixirWeb.WebRuntime` (21 lines): `orchestrator/0` + `snapshot_timeout_ms/0`
  reading the endpoint config from Application env (same keys tests already injected) — the ONE
  narrow accessor; no service locator.
- DashboardLive, AdminLive, ObservabilityApiController now call `WebRuntime.orchestrator()` /
  `WebRuntime.snapshot_timeout_ms()`; the duplicated `Endpoint.config(...) || default`
  resolution (3-4 copies) is deleted.
- Test injection preserved: tests still set the same endpoint env keys, so custom
  orchestrator/timeout tests pass unchanged. Test baseline unchanged at 710.

