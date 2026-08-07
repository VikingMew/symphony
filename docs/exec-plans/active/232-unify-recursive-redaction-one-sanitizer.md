# 232 Unify recursive redaction (one sanitizer)

## Goal

Merge the four parallel sensitive-field scrubbing implementations into a single `Redaction.payload/2` path.

## Status

Active.

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
