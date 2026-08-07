# 235 Normalize Codex protocol events (shared parsing)

## Goal

One protocol-event normalization path shared by run history, message humanizer, and update handling; kill the string-path soup.

## Status

Active.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Redundancy [3] (medium) + bad smell [4] (medium): run_history.ex:205-275, message_humanizer/methods.ex:21-228, codex/update.ex:86-91,256-283.

Persisted history and live messages separately parse/format the same Codex protocol methods (`turn/completed`, `item/completed`, `thread/tokenUsage/updated`, `account/rateLimits/updated`); RunHistory already calls MessageHumanizer but overrides the same events. Payloads stay atom/string/camelCase-mixed; `Payload.get_path/3` already supports candidate keys per level but call sites copy full paths anyway. Protocol changes require coordinated edits in Update, RunHistory, TokenUsage, and Humanizer.

## Scope

- Introduce a `Codex.Protocol` boundary that normalizes incoming events into one internal event struct (or at minimum: one shared field-extraction layer using `Payload.get_path` with per-level candidate keys).
- Re-point run_history, message_humanizer/methods, and update handling at the shared layer; keep per-consumer copy/formatting differences.
- Remove duplicated path strings in the three modules.

## Out of Scope

- Rewriting the wire format; changing displayed copy.

## Acceptance Criteria

- A single event parsed once produces the same extracted fields for history and humanizer.
- No hand-rolled multi-variant path lookups remain in the three modules (use the shared extraction).
- Existing run_history/humanizer/update tests pass unchanged.

## Test Cases

- Table-driven: one sample event per method through both history and humanizer => identical fields.
- Protocol variant coverage (atom/string/camelCase keys).

## Implementation Notes

Start with shared field extraction; full struct normalization can follow. Don't change user-visible copy in this plan.

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
