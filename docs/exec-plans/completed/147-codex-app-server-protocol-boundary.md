# 147 - Codex App Server Protocol Boundary

Status: Completed

## Problem

`SymphonyElixir.Codex.AppServer` still owns JSON-RPC framing, pending-line buffering, startup response parsing, turn response parsing, non-JSON stream logging, and protocol message detection.

Startup command construction has already been extracted, but the app-server module remains a large mix of process I/O, protocol decoding, turn lifecycle, dynamic tool routing, and approval policy handling.

Protocol parsing is a stable boundary that can be tested without starting Codex.

## Goal

Extract Codex app-server protocol framing and response decoding into a focused module such as `SymphonyElixir.Codex.Protocol`.

`AppServer` should own port lifecycle and turn orchestration; the protocol module should own message encoding, line buffering, JSON decoding, request/response matching, and protocol error classification.

## Plan

1. Inventory protocol helpers in `app_server.ex`, including send message, receive loop parsing, startup response handling, turn response handling, and stream-line classification.
2. Extract message encoding and response decoding into a pure protocol module.
3. Represent decoded stream items as explicit tagged values, for example `{:response, id, payload}`, `{:notification, method, payload}`, `{:partial, line}`, `{:malformed, line}`.
4. Keep timeout loops and port messages in `AppServer`.
5. Add focused tests for partial lines, malformed JSON, request-id matching, startup responses, turn responses, and non-protocol stream lines.
6. Preserve emitted event payloads and log behavior unless a test documents an intentional change.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/protocol_test.exs test/symphony_elixir/app_server_test.exs`
  - Result: `33 tests, 0 failures`.
- `rg -n "send_message|receive_loop|handle_incoming|await_response|handle_response|await_startup_response|protocol_message_candidate|log_non_json_stream_line" lib test`
  - Result: JSON encoding, request-id matching, stream classification, malformed detection, and stream log severity now live in `Codex.Protocol`.
  - Remaining `AppServer` matches are port lifecycle and timeout loops, plus small wrappers that send protocol-encoded messages to the port.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

`AppServer` still owns receive-loop timeout control and port message waiting. The extracted protocol boundary owns pure framing, line completion, JSON decoding, response matching, turn stream classification, malformed-candidate detection, and non-JSON stream log classification.
