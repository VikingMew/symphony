# 071 Codex MCP Elicitation Hard Stop

## Goal

Stop treating Codex MCP elicitation requests as ordinary notifications. When
Codex emits an MCP elicitation request in the non-interactive Symphony runtime,
surface it immediately as a blocked turn instead of waiting for stall timeout.

## Status

Completed.

## Background

Recent CCR-3 runs repeatedly reached this sequence:

- `mcpServer/elicitation/request`;
- thread token usage update;
- rate limits update;
- no further terminal event until stall handling.

The current parser classifies `mcpServer/elicitation/request` as a generic
notification. Codex is actually waiting for an interactive response, but
Symphony is running without an interactive operator channel for that prompt.
This makes the run appear to end at the rate-limit update even though the real
blocker is the MCP elicitation.

The default Codex approval policy already rejects MCP elicitations, but the
runtime still needs to recognize the emitted event and terminate the turn
clearly.

## Scope

- Recognize MCP elicitation request methods from Codex app-server output.
- Emit the existing blocked-turn event path so dashboard/session history shows
  a clear input-required blocker.
- Humanize MCP elicitation events with server/tool/prompt details when present
  so operators can see which MCP integration blocked the run.
- Return `{:error, {:turn_input_required, payload}}` instead of continuing the
  receive loop.
- Add focused app-server coverage for `mcpServer/elicitation/request`.
- Preserve existing handling for normal notifications, rate-limit updates,
  tool calls, and command approval requests.

## Out of Scope

- Adding an interactive UI to answer MCP elicitations.
- Changing Codex approval policy defaults.
- Changing retry/backoff policy.
- Changing Linear state transitions after the failure.

## Acceptance Criteria

- A fake Codex app-server that emits `mcpServer/elicitation/request` causes
  `AppServer.run/3` to return `{:error, {:turn_input_required, payload}}`.
- The blocked event is emitted through the existing `:turn_input_required`
  message path.
- Session history and notification text identify MCP elicitation requests using
  available server, tool, and prompt fields.
- Rate-limit notifications remain ordinary notifications.
- Focused app-server tests pass.
- `mise exec -- mix format` passes.
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs` passes.

## Test Cases

- MCP elicitation request after turn start returns `:turn_input_required`.
- MCP elicitation display includes server/tool/prompt details when those fields
  are present.
- Existing `turn/input_required` test remains green.
- Existing approval-required and normal notification tests remain green.

## Implementation Notes

- Prefer extending `needs_input?/2` in `SymphonyElixir.Codex.AppServer` rather
  than adding a separate event type unless the existing blocked-turn UI is
  insufficient.
- Match the observed method `mcpServer/elicitation/request`; optionally accept
  adjacent MCP elicitation method spelling if it is low risk.
- Keep the session-history wording readable through the existing
  `turn_input_required` humanization.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs` passed: 20 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs` passed: 37 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/orchestrator_status_test.exs` passed: 57 tests, 0 failures.
- `mise exec -- mix lint` passed.
- `mise exec -- mix test` passed: 292 tests, 0 failures, 2 skipped.

## Completion Deviations

- Expanded scope slightly to improve observability for the same blocker:
  `StatusDashboard` now humanizes MCP elicitation requests with server, tool,
  and prompt details when present.

## Dependencies

- Existing Codex app-server protocol parser.
- Existing session-history handling for `:turn_input_required`.

## Handoff Notes

This plan is intentionally narrow. It makes the blocker explicit; it does not
teach Symphony how to answer arbitrary MCP elicitations.
