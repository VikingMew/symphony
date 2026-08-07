# 148 - Codex Tool Request Handler Boundary

Status: Completed

## Problem

`SymphonyElixir.Codex.AppServer` still handles dynamic tool calls, approval requests, elicitation hard stops, request-user-input auto answers, and dynamic tool result normalization inline with the port receive loop.

This is a separate policy boundary from protocol transport. It determines which Codex requests can be answered non-interactively, which require hard stop, and how tool results are serialized.

Keeping this in `AppServer` makes the receive loop harder to reason about and makes tool policy tests depend on app-server internals.

## Goal

Extract tool/request handling into a module such as `SymphonyElixir.Codex.ToolRequestHandler`.

The handler should consume decoded protocol requests plus current policy flags and return explicit actions: reply, emit update, require input, reject, or stop.

## Plan

1. Inventory helpers related to `maybe_handle_approval_request/6`, dynamic tool execution, request-user-input answers, elicitation detection, and result normalization.
2. Define an action-returning API that does not directly write to the port.
3. Move approval/request-user-input policy and dynamic tool result shaping into the handler.
4. Keep `AppServer` responsible for sending replies and continuing/stopping the receive loop.
5. Add focused tests for auto approvals, denied approvals, MCP elicitation hard stops, request-user-input fallback answers, unsupported tools, and dynamic tool result serialization.
6. Preserve current non-interactive safety behavior.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/tool_request_handler_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/app_server_test.exs`
  - Result: `41 tests, 0 failures`.
- `rg -n "maybe_handle_approval_request|approve_or_require|requestUserInput|elicitation|normalize_dynamic_tool_result|dynamic_tool_content_items|tool_request_user_input|needs_input\\?" lib test`
  - Result: approval/tool/request-user-input policy helpers now live in `Codex.ToolRequestHandler`; `AppServer` keeps only the call site that sends reply actions and controls the receive loop.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

The handler consumes decoded method/payload maps rather than a broader protocol event struct. That keeps this slice focused on tool/request policy while `Codex.Protocol` remains responsible for transport decoding.
