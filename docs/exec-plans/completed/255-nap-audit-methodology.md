# 255 Nap audit methodology: tool-driven redundancy discovery

## Goal

Upgrade the nap operator profile's default prompt to the 2026-08-16 audit methodology (see
`docs/operator-profiles-standardization-design.md` §3.1): tool-driven discovery before
manual review, five new audit dimensions, richer issue output format, and anti-false-positive
discipline. nap remains a *method for proposing deletion/optimization directions* — it does not
delete or modify anything itself.

## Status

Completed.

## Background

The current nap prompt (schema.ex ~line 705) covers three problem categories (redundancy,
unreasonable mutual dependencies, dead weight) judged against Linus & Carmack criteria, and
requires each issue to carry title/evidence/violated criterion/complexity impact/fix direction.

It does not tell the agent *how to find* candidates (no mechanical scans), misses four
recurring redundancy classes observed in real cleanup work, and its issue format lacks a
verification path — so issues it produces cannot be executed confidently by the downstream
Codex pipeline.

The methodology added to the design doc on 2026-08-16 was distilled from a code-archaeology
study of DeepSeek Harness (deepseek-ai/deepseek-harness): a 65-day pre-release cleanup that
removed ~190k lines / 1,797 files, driven by tool gates (knip/jscpd), archived-not-deleted
decision notes, and "gate first, then zero the debt" deduplication. nap is the *proposal*
side of that pipeline; this plan only upgrades the proposal prompt, not the execution side.

## Scope

- `lib/symphony_elixir/config/schema.ex`: upgrade the `nap` profile's default prompt template
  (the single string at the `"nap" =>` entry) to include, in the established prompt style:
  1. **Mechanical scan pre-step**: run `mix xref graph`, dependency-unused checks,
     credo duplicate-code/complexity checks, and `mix dialyzer` (with the explicit caveat that
     OTP28 `unused_fun` has known false positives and tool output must be manually re-checked)
     before/while reviewing; tool output is evidence, not verdict.
  2. **New audit dimensions**: stale exemption lists (`.dialyzer_ignore.exs`, credo
     exemptions, `@tag :skip` tests, disabled lint rules — is the covered code still there,
     can the entry be tightened, can the whole exemption baseline be dropped); unconsumed
     public API/events (public exports, GenServer cast/call, event topics with no real
     consumer, backed by `mix xref graph`); hand-maintained documentation that already has a
     source-of-truth in code (config keys derivable from schema.ex, module lists, indexes) —
     stale docs should be archived, not deleted; fix directions should prefer "introduce a
     gate, zero the debt, then drop the exemption baseline" over one-off cleanup.
  3. **Issue output format**: add discovery path (mechanical scan output vs manual review)
     and verification path (how to prove behavior is unchanged after removal: `make all`,
     targeted tests, dialyzer) to every issue.
  4. **Anti-false-positive discipline**: re-check tool output manually (OTP28 dialyzer
     caveat), distinguish "pure deletion" from "reorganize/migrate" (capability still in use
     but mis-placed → propose reorg, not deletion), and write "Keep as-is" for uncertain
     candidates instead of noise.
- `profiles.yml`: sync the `nap` prompt section with the schema.ex default so the two match
  byte-for-byte (plan 248 acceptance rule).
- Tests: update/extend any test that asserts the nap prompt content or the schema.ex ↔
  profiles.yml consistency, so the new template is covered.

## Out of scope

- `day_dreaming` profile — unchanged.
- `issue_create` tool, orchestrator, dashboard, scheduling — unchanged.
- Design doc (`docs/operator-profiles-standardization-design.md`) — maintained by Hermes;
  do not edit.
- Any actual deletion/refactor of symphony code — nap only proposes; execution is separate.

## Acceptance criteria

1. `schema.ex` nap default prompt contains all four methodology blocks: mechanical scan
   pre-step (with OTP28 dialyzer caveat), the new audit dimensions (stale exemptions,
   unconsumed public API/events, hand-maintained docs with a code source of truth,
   gate-then-zero fix directions), enriched issue format (discovery path + verification
   path), and anti-false-positive discipline (re-check tool output, deletion vs reorg,
   Keep as-is).
2. The existing three problem categories and the five Linus & Carmack criteria remain
   present in the prompt (no regression).
3. `profiles.yml` nap section matches the schema.ex default byte-for-byte (the existing
   consistency check/test passes).
4. `mix specs.check` passes; targeted tests for the touched modules pass; `make all`
   passes (lint segment 0 [F]; coverage ≥85%; dialyzer no new warnings vs baseline).
5. New-workflow initialization still seeds nap from the standard template (no change to
   that path; existing test proves it).

## Test cases

- schema.ex ↔ profiles.yml consistency test (existing; must pass unchanged after sync).
- Prompt-content assertion tests: update to assert the new blocks are present (or rely on
  the consistency test + a snapshot of the template if that is the established pattern).
- Full suite: no regressions beyond the known flaky families (see symphony-development
  skill; attribute any flake via isolated re-run before accepting).

## Implementation notes

- Keep the prompt in the existing single-string style; do not restructure schema.ex.
- The prompt is English (matching the current nap template language).
- After editing schema.ex, regenerate/sync `profiles.yml` from the same source text
  (plan 248 established the byte-identical rule; check how the sync is done — manual copy
  or a script — and follow it).
- Do not touch DB `workflow_versions.yaml_config` rows in this plan; existing workflows may
  keep their current nap prompt until a "reset to standard" path is used (per design §4).

## Verification

- `mise exec -- mix format --check-formatted` — PASS (Hermes re-ran).
- `mise exec -- mix compile --warnings-as-errors` — PASS (Codex).
- `mise exec -- mix specs.check` — PASS (Hermes re-ran: all public functions have @spec or exemption).
- `mise exec -- mix test test/symphony_elixir/prompt_builder_test.exs` — PASS: 16 tests, 0 failures (Hermes re-ran).
- Targeted tests (Codex) — PASS: 72 tests, 0 failures.
- `mise exec -- mix test` (full suite, Codex) — PASS: 744 tests, 0 failures, 2 skipped.
- `mise exec -- mix test --cover` — PASS (Hermes re-ran, exit 0): 85.59% coverage (>= 85 gate).
- Lint (`mix credo --strict`, Hermes re-ran) — 0 [F]; 19 readability + 1 design (pre-existing baseline, no new).
- `mix dialyzer` — 5 `pattern_match_cov` warnings, all in untouched files (protocol.ex x2, token_usage.ex, config.ex, orchestrator.ex); identical to baseline, none introduced by this plan.
- Byte-compare schema.ex nap template vs profiles.yml nap section — byte-identical (Codex reports 3,946 bytes both sides).
- `make all` as a single target — NOT runnable in the Codex sandbox (Mix/Hex blocked from network/sockets by sandbox, `:eperm`/`:eaccess`); all its components verified independently above.

## Completion Deviations

- `make all` could not be run as a single target inside the Codex sandbox: Mix/Hex setup needs local sockets, network, and `~/.hex/cache.ets` persistence, which `--sandbox workspace-write` denies (`:eperm`, `:eaccess`, DNS failures). All make-all components (format, compile, lint, coverage, dialyzer) were run and verified independently — see Verification.
- Dialyzer reports 5 pre-existing `pattern_match_cov` warnings (coverage-class, not correctness) in files untouched by this plan: `codex/protocol.ex:378,459`, `codex/token_usage.ex:72`, `config.ex:221`, `orchestrator.ex:2961`. Not introduced here; recorded as known baseline.
- Codex added a clarifying sentence to the nap prompt beyond the plan's letter: "This profile proposes deletion or optimization directions; it does not delete." — faithfully strengthens the nap-as-proposal positioning from the design doc §3.1; kept.
- Codex extended `prompt_builder_test.exs` with 20 fine-grained assertions (one per methodology element) instead of a coarse snapshot; the consistency test for schema.ex ↔ profiles.yml still passes unchanged.

## Dependencies

- Design doc: `docs/operator-profiles-standardization-design.md` §3.1 (updated 2026-08-16).

## Handoff notes

- This plan only changes the nap *prompt contract*. After it lands, a future nap run on any
  project (e.g. koroni) will produce issues with discovery/verification paths; the execution
  side (Codex fixing those issues) is out of scope here.
