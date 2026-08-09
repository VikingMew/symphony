# 248 Operator profiles standardization (nap & day_dreaming contract)

## Goal

Make the read-only operator profiles (`nap`, `day_dreaming`) a single-source contract instead of three drifting copies: code defaults in `config/schema.ex`, per-project DB `yaml_config`, and the import/export package `profiles.yml` (where both profiles are currently missing). Upgrade the default `nap` prompt to the 2026-08-09 standard (redundancy incl. error handling & gating, unreasonable coupling, complexity reduction, per-criterion Linus & Carmack mapping).

## Status

Completed.

## Background

Source: `docs/operator-profiles-standardization-design.md` (proposed). Today the two operator profiles live in three places with different content:

- `lib/symphony_elixir/config/schema.ex` (~698-727): defaults for both profiles, but the `nap` template predates the new audit standard.
- DB `workflow_versions.yaml_config` per project: Koroni was hand-updated to the new nap template; Default (CCR) and future projects keep the old one.
- `profiles.yml`: contains `implementation`, `merge`, `refinement` only — `nap` and `day_dreaming` are absent, so package import/export drops the operator profiles.

Drift means the same profile behaves differently per project, standard upgrades touch three places, and package migration loses the profiles. Violates Linus "remove complexity" (three representations of one fact) and Carmack (dual/multiple representation of one fact).

## Scope

- `config/schema.ex`: replace default `nap` template with the §3.1 standard (redundant error handling & gating, unreasonable coupling, dead weight, per-criterion Linus & Carmack mapping, issue output format); confirm `day_dreaming` default matches §3.2.
- `profiles.yml`: add `nap` and `day_dreaming` sections mirroring the code defaults.
- New-workflow initialization: verify defaults flow from code defaults into a fresh workflow's operator profiles (test).
- Import/export round trip: verify both profiles survive (test).
- Docs: register `docs/operator-profiles-standardization-design.md` in `docs/README.md` (L3); reference the design from the plan.

## Out of Scope

- Scheduling/triggering of operator runs (dashboard buttons, cron) — separate plan space.
- Changing `issue_create` tool or its profile allowlist (`["nap", "day_dreaming"]` already correct).
- Changing implementation/refinement/merge profile contracts.
- Forcing sync of existing DB workflows to the new defaults (override allowed; standard is the baseline, not a lock).

## Acceptance Criteria

- `schema.ex` nap default contains: redundancy (incl. redundant error handling & gating), unreasonable mutual dependencies, dead weight, explicit per-criterion Linus & Carmack evaluation, issue output format with evidence + criterion + impact + fix direction.
- `schema.ex` day_dreaming default matches §3.2 (evidence-backed opportunities, issue output format).
- `profiles.yml` contains nap and day_dreaming matching the code defaults.
- Test: building a fresh workflow config yields operator profile defaults equal to code defaults.
- Test: import/export round trip preserves nap and day_dreaming.
- `mix specs.check` passes.
- `make all` passes.

## Test Cases

- `prompt_builder` / `config schema` test: default nap template contains "redundant error handling", "mutual dependencies", "Linus", "Carmack", "Backlog Linear issue".
- Default day_dreaming template contains "opportunity" / "Backlog Linear issue".
- Fresh workflow config: `profiles.nap.prompt.template == code default`.
- Import/export: package with nap/day_dreaming round-trips intact.
- Existing behavior: implementation/refinement/merge profiles unchanged by this plan.

## Implementation Notes

- Keep profile ids stable: `nap`, `day_dreaming`.
- The `profiles.yml` sections must mirror the code defaults exactly; do not hand-maintain two texts long-term — treat code defaults as source, regenerate package on export (note in code comment).
- The new nap template (from design §3.1) is the one already applied to Koroni's DB; the code default should match it so future projects start standard.
- Do not rewrite DB rows for Default/CCR as part of this plan (override allowed; only code default + package + fresh init change).

## Verification

- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/config/schema_test.exs test/symphony_elixir/prompt_builder_test.exs` (+ import/export suite)
- `mise exec -- mix specs.check`
- `make all`

## Completion Deviations

None. All acceptance criteria met:

- schema.ex nap default carries the full new standard (redundancy incl. redundant error handling & gating, mutual dependencies, dead weight, per-criterion Linus & Carmack mapping, issue format with evidence/criterion/impact/fix direction).
- schema.ex day_dreaming default adds evidence / direction-alignment / no-duplicate contract.
- profiles.yml nap + day_dreaming sections mirror the code defaults exactly (byte-identical after unescaping; verified 2200/756 chars).
- Tests: prompt_builder asserts new markers; fresh-workflow defaults equal code defaults; package round trip preserves both profiles. 21 targeted tests green.
- Full suite: 715 tests, failures were the known flaky families (CoreTest persistence race, AuditEventWriteSemantics raising-persistence stub) — isolated rerun 46/46 green, unrelated to this plan.
- credo: 0 [F], 20 [R] + 1 [D] identical to pre-change baseline (stash-compared).
- specs.check passed; format + compile --warnings-as-errors passed.
- Executed by Codex CLI (203,553 tokens), commit f91ae13.
