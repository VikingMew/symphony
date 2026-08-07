# 176 Message Humanizer Wrapper Method Split

## Goal

Continue splitting `Codex.MessageHumanizer` by extracting wrapper-event and JSON-RPC method handling into focused modules.

## Status

Completed.

## Background

Plan 162 extracted usage/rate-limit formatting, but `lib/symphony_elixir/codex/message_humanizer.ex` is still over 800 lines. It still owns:

- wrapper event dispatch;
- JSON-RPC turn/thread/account method display;
- MCP startup and elicitation details;
- command/file-change message formatting;
- streaming delta preview extraction;
- fallback command normalization.

This remains a monolith around upstream Codex event churn. Adding one more event still requires editing a large multi-family module.

## Scope

- Extract wrapper-event handling into a module such as `Codex.MessageHumanizer.WrapperEvents`.
- Extract JSON-RPC method handling into a module such as `Codex.MessageHumanizer.Methods`.
- Keep shared formatting primitives small and explicit.
- Keep the public `MessageHumanizer.humanize_codex_message/1` facade.
- Move family-specific tests beside the extracted modules.

## Out of Scope

- Changing display strings.
- Removing support for known upstream event variants.
- Changing persisted Codex update payloads.
- Changing run history/event presenter callers.

## Acceptance Criteria

- `message_humanizer.ex` is materially smaller and primarily dispatches to family modules.
- Wrapper and JSON-RPC method tests can be run independently.
- Existing dashboard, run history, event presenter, and status dashboard tests still pass.
- Adding a new upstream event family does not require editing unrelated formatter clauses.

## Verification

- `mise exec -- mix test test/symphony_elixir/codex/message_humanizer_test.exs test/symphony_elixir/codex/message_humanizer_methods_test.exs test/symphony_elixir/codex/message_humanizer_wrapper_events_test.exs`
- Focused method and wrapper formatter modules were added under `lib/symphony_elixir/codex/message_humanizer/`.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.
