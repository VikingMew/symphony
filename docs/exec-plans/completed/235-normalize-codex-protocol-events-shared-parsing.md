# 235 Normalize Codex protocol events (shared parsing)

## Goal

One protocol-event normalization path shared by run history, message humanizer, and update handling; kill the string-path soup.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 22 [R] + 1 [D], down from 23 [R] + 2 [D])
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 684 tests, 3 failures (full suite). The 3 failures are the SAME
  pre-existing cross-file concurrency race already documented in plan 233 (CoreTest
  "run-start persistence failure" + WorkflowStoreTest x2), identical to the plan-232 control run.
  No new failures. Isolated runs all green: workflow_store_test + core_test + protocol_test +
  codex_update_test + methods_test + token_usage_test together = 63 tests, 0 failures.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (protocol.ex, run_history.ex, token_usage.ex,
  update.ex, message_humanizer/methods.ex + 2 test files)

## Completion Deviations

- Shared layer implemented by EXTENDING the existing `Codex.Protocol` boundary (the plan allowed
  either) with `normalize_event/2` returning a typed `%Protocol.Event{}` struct. The struct keeps
  `raw` + `params` and exposes canonical fields (method normalized to "turn/completed"-style
  strings, id/session/thread/turn/item ids, item/turn status/phase/text, token counts, rate limits,
  delta, plan entries, command, change count, question, auth mode, tool, errors, timestamps), each
  extracted with `Payload.get_any/get_path` per-level candidate keys covering atom/string/camelCase
  variants.
- `TokenUsage.absolute_usage/1` collapsed its hand-rolled 17-path lookup matrix into a single
  `Protocol.normalize_event` call; run_history and message_humanizer/methods extraction re-pointed
  at the normalized event (per-consumer copy/formatting kept unchanged — no user-visible copy
  changed).
- `update.ex` event classification (`codex_operation/3`, rate-limit update detection) now reads the
  normalized nested method instead of hand-walking payload paths.
- New tests: protocol_test.exs normalize_event coverage (atom method names -> canonical strings,
  nested per-level key variants, absolute-usage extraction); codex_update_test.exs mixed-key
  streaming-field integration + normalized nested rate-limit detection. Test baseline 680 -> 684.
- Codex hit and fixed a credo fatal complexity finding on the Event struct during the run (split
  extraction into semantic helpers); final credo is 0 [F].

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
