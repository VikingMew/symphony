# 228 Fix falsy config reads (false treated as missing)

## Goal

Restore the ability to DISABLE dashboard and rate-limit gate by fixing truthiness-based config reads that treat a legitimate `false` value as a missing field.

## Status

Active.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Bad smell [1] (high): Payload.get_any/3, StatusDashboard, RateLimitGate.setting/2.

`Payload.get_any/3` uses `Enum.find_value`, so `Map.fetch` returning `false` keeps searching and falls back to the default — `dashboard_enabled: false` is resurrected as the default `true`. `RateLimitGate.setting/2` uses `Map.get(atom) || Map.get(string)`, turning `%Schema.Codex{rate_limit_gate_enabled: false}` into `nil`, after which `bool(nil, true)` re-enables the gate. Users cannot disable either feature. Payload tests never cover `false`; the rate-limit form test only covers `"true"`.

## Scope

- `lib/symphony_elixir/payload.ex` `get_any/3`: use sentinel-aware lookup (`Map.fetch` / `Enum.reduce_while`) that falls back ONLY when the key is absent, never on `false`/`nil` values.
- `lib/symphony_elixir/codex/rate_limit_gate.ex` `setting/2`: same fix (don't `||`-chain map gets).
- `lib/symphony_elixir/status_dashboard.ex` `dashboard_enabled` read: verify it now honors `false`.
- Audit other `Map.get(...) || Map.get(...)` / `find_value` patterns in lib/ for the same class of bug (report any found in Deviations).

## Out of Scope

- Any behavior change beyond preserving explicit false values.

## Acceptance Criteria

- `dashboard_enabled: false` in the active workflow config disables the dashboard; `rate_limit_gate_enabled: false` disables the gate (both verified by tests).
- Tests cover explicit `false` for both fields, not only `"true"`/`true`/absent.
- No other `||`-chain config read of this class remains in lib/.

## Test Cases

- Unit: `Payload.get_any/3` with `false` values in both atom-keyed and string-keyed maps.
- Unit: `RateLimitGate.setting/2` with `%Schema.Codex{rate_limit_gate_enabled: false}`.
- E2E-ish: dashboard disabled with explicit false renders without dashboard.
- Existing config/status_dashboard/rate_limit_gate tests keep passing.

## Implementation Notes

The gate already has functional fallbacks for missing/non-map inputs; only the falsy-value path is broken. Keep the fix minimal — sentinel lookup, not a rewrite.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (664 baseline, 0 failures, 2 skipped; known flaky:
  OrchestratorStatusTest `:sys.get_state` timeout, HookRunnerTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

## Dependencies

None.

## Handoff Notes

Executed by Codex CLI in a clean worktree (`--sandbox workspace-write`). Prompt must
carry: file whitelist, environment-noise rules (Mix.PubSub/port/socket errors in sandbox
are noise — continue), forbid touching docs/exec-plans and design docs, forbid adding
`.dialyzer_ignore.exs` entries, forbid custom build environments (`_build/codex_*`),
report format (Completed / Validation / Deviations / Blockers). Reviewer runs the full
gate sequence outside the sandbox, reviews the diff for behavior equivalence, archives
this plan, and commits.
