# 232 Unify recursive redaction (one sanitizer)

## Goal

Merge the four parallel sensitive-field scrubbing implementations into a single `Redaction.payload/2` path.

## Status

Completed.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Redundancy [2] (high): event_presenter.ex:173-183, linear_tool_audit.ex:140-160, codex/update.ex:373-394,431-439, web/admin/observability_presenter.ex:63-76.

Four modules independently implement recursive scrubbing of `token/secret/authorization/api_key/cookie` keys, with divergent string-credential scrubbing and truncation rules; ObservabilityPresenter only scrubs sensitive keys, not credentials inside ordinary strings. Behavior has already diverged — a leak/different-truncation risk across observability entry points. Existing `Redaction` shares only part of the string handling.

## Scope

- Consolidate into `Redaction.payload/2` (or a single new module): recursive key scrubbing + string credential scrubbing + DateTime conversion + length caps, with one policy.
- Re-point all four call sites to the single implementation; presenters keep only display duties.
- Ensure ObservabilityPresenter now scrubs string credentials too (closing the divergence).

## Out of Scope

- Changing the exact redaction policy beyond unification; log-format changes.

## Acceptance Criteria

- All four entry points produce identical scrubbing for the same payload (property-style test comparing outputs).
- String-embedded credentials are scrubbed everywhere, not just in sensitive keys.
- Existing presenter/audit tests pass with the unified behavior.

## Test Cases

- Golden tests: same payload through all four presenters => identical scrubbed output.
- Credential-in-string cases for each presenter.

## Implementation Notes

Security-sensitive: unify policy first, then call sites. Do not weaken the strictest current behavior.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 32 [R] + 2 [D], unchanged from 231)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 679 tests, 0 failures, 2 skipped (full suite, single run; +2 redaction tests)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (redaction.ex + 4 call sites + redaction_test.exs)

## Completion Deviations

- Unified truncation policy is 500 bytes (byte_size) with the `"... (truncated)"` suffix for ALL
  string values. Previous per-site limits were 1200 chars (linear_tool_audit), 1000 bytes (update
  persisted path), 500 bytes (update debug path), and no truncation (event_presenter,
  observability_presenter) — the unified 500-byte cap is stricter than every prior behavior,
  satisfying "do not weaken the strictest current behavior".
- `Redaction.payload/2` is a new public API: recursive sensitive-key scrubbing (token/secret/
  authorization/api_key/cookie), string-embedded credential scrubbing via `credentials/1`, DateTime
  -> ISO8601 conversion (matching update.ex's prior behavior), and the byte cap. All four call sites
  re-pointed; presenters kept only display duties (inspect/truncate of the final string).
- ObservabilityPresenter now scrubs credentials inside ordinary strings (previously only sensitive
  keys) — this closes the divergence the plan called out.
- linear_tool_audit's separate `bound/1` (1200 chars, String.length) is gone; its `safe_arguments`
  and `normalize_success_result` now use `Redaction.payload(..., 500)`.
- New property-style test: two payload shapes pushed through EventPresenter.row, LinearToolAudit
  audit events, Update debug + persisted paths, and ObservabilityPresenter produce byte-identical
  scrubbed output with no secret leakage (`ordinary-secret` / `key-secret` / `session-secret`
  refuted in the inspected output).

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
