# 199 Message Humanizer Method Family Follow Up

## Goal

Split `Codex.MessageHumanizer.Methods` by JSON-RPC method family so the humanizer no longer concentrates unrelated protocol cases in one module.

## Status

Completed.

## Background

Completed plan 176 extracted wrapper and method modules from the message humanizer, but `lib/symphony_elixir/codex/message_humanizer/methods.ex` still remains over 500 lines. It owns several unrelated method families:

- thread and turn lifecycle;
- diff and plan updates;
- approval and request-input flows;
- account/status messages;
- item lifecycle events;
- dynamic tool messages;
- MCP elicitation;
- command and file-change rendering;
- fallback normalization.

The remaining module is better than the original wrapper, but still too broad for confident protocol changes.

## Scope

- Group method handlers by stable protocol family.
- Extract at least one coherent family into a focused module first.
- Preserve existing message text and payload compatibility.
- Keep shared fallback/normalization helpers shared rather than copied.
- Add narrow tests for the extracted family and keep existing method tests green.

## Out of Scope

- Rewriting all humanized messages.
- Changing operator-facing copy unless necessary to preserve behavior.
- Changing Codex event ingestion.
- Reworking run-history storage.

## Acceptance Criteria

- `Codex.MessageHumanizer.Methods` loses at least one coherent method family.
- Extracted modules have names that match protocol ownership, not implementation convenience.
- Existing humanizer tests pass without broad fixture rewrites.
- Unknown/fallback methods still behave as before.
- Future method additions have an obvious owner module.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/message_humanizer_methods_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/message_humanizer_test.exs`
- `wc -l lib/symphony_elixir/codex/message_humanizer/methods.ex lib/symphony_elixir/codex/message_humanizer/*.ex`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 162 for message humanizer method boundary.
- Completed plan 176 for message humanizer wrapper/method split.

## Handoff Notes

Do not split by arbitrary line count. Split by protocol family so readers can find the behavior by method ownership.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

