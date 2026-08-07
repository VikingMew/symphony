# 228 Fix falsy config reads (false treated as missing)

## Goal

Restore the ability to DISABLE dashboard and rate-limit gate by fixing truthiness-based config reads that treat a legitimate `false` value as a missing field.

## Status

Completed.

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

Executed by Codex CLI (0.147.0, `--sandbox workspace-write`) and independently verified
by the reviewer:

- `lib/symphony_elixir/payload.ex` `get_any/3`: `Enum.find_value` -> `Enum.reduce_while`
  with `Map.fetch`; halts on a PRESENT value (including `false`/`nil`), continues only on
  `:error`. API and absent-key semantics unchanged.
- `lib/symphony_elixir/codex/rate_limit_gate.ex` `setting/2`: `Map.get(atom) ||
  Map.get(string)` -> `Map.fetch(atom)` with string-key fallback only on `:error`.
- `lib/symphony_elixir/status_dashboard.ex`: no change needed (reads via Payload);
  a regression test proves explicit false disables it.
- Tests added: `payload_test.exs` (false atom-keyed / false string-keyed / nil preserved),
  rate-limit gate (`%Schema.Codex{rate_limit_gate_enabled: false}` at 100% used -> `:allow`),
  status dashboard (explicit false disables, `:sys.get_state(pid).enabled` refuted).
- Gates (reviewer, outside sandbox): `mix test` -> **669 tests, 0 failures, 2 skipped**
  (664 + 5 new); `mix format --check-formatted` pass; `mix compile --warnings-as-errors`
  pass; credo 0 [F] (35 [R] + 2 [D] unchanged); `mix exec_plans.check` pass.
- Diff scope: exactly 4 whitelisted files + 1 new test file.

## Completion Deviations

- Audit of other `Map.get(...) || Map.get(...)` chains: remaining sites are in
  `event_presenter.ex` (atom/string dual-key fallback for payload fields whose legal values
  are strings/structs, never `false`) — same-class falsy bug does NOT apply there. No change
  made; noted for plan 235's shared-extraction work.

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
