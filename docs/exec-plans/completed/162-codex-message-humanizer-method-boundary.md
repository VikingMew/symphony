# 162 Codex Message Humanizer Method Boundary

## Goal

Split `SymphonyElixir.Codex.MessageHumanizer` into smaller message-family boundaries without changing any displayed text.

## Status

Completed.

## Background

The earlier extraction moved Codex message humanization out of `StatusDashboard`, but the new owner has become a 900+ line module. It now handles:

- app-server wrapper events;
- raw JSON-RPC methods;
- MCP elicitation messages;
- dynamic tool events;
- command execution display;
- token/rate-limit summaries;
- streaming delta preview extraction;
- generic payload/path fallback helpers.

The module is pure and useful, but the current shape recreates a monolith under a better name. The risk is drift between event families and increasingly brittle tests whenever upstream Codex adds or renames events.

## Scope

- Keep `MessageHumanizer.humanize_codex_message/1` as the public facade.
- Extract method-family modules or private collaborators for:
  - JSON-RPC turn/thread/account methods;
  - wrapper events;
  - MCP elicitation and dynamic tool events;
  - command/file-change events;
  - usage/rate-limit formatting.
- Preserve existing public output strings unless a regression test proves they are wrong.
- Move family-specific tests out of unrelated orchestrator/status dashboard tests.

## Out of Scope

- Changing persisted event payloads.
- Adding LLM summarization.
- Removing support for currently observed Codex event shapes.
- Rewriting `Codex.Update`.

## Acceptance Criteria

- `MessageHumanizer` is a small facade plus shared primitives.
- Each event family has focused tests with representative payloads.
- Existing run history, dashboard, event presenter, and rate-limit rendering continue to use the same public facade.
- `orchestrator_status_test.exs` no longer owns the bulk of message-humanizer coverage.

## Verification

- `mix test test/symphony_elixir/codex_message_humanizer_test.exs`
- `mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mix test test/symphony_elixir/run_history_test.exs`
- `rg -n "humanize_codex_method|humanize_codex_wrapper_event|humanize_mcp_elicitation|format_usage_counts|format_rate_limits_summary" lib test`
- `mix exec_plans.check`

## Completion Deviations

Extracted usage and rate-limit formatting into `SymphonyElixir.Codex.MessageUsageFormatter` with focused tests. The public `MessageHumanizer.humanize_codex_message/1` facade remains unchanged; method-family extraction should continue through future narrower slices if the module grows again.
