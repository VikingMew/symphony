# 179 App Server Integration Harness Thinning

## Goal

Thin the remaining `app_server_test.exs` process harness after startup, protocol, and tool policy boundary tests have been added.

## Status

Completed.

## Background

Plan 169 completed with focused boundary tests, but `test/symphony_elixir/app_server_test.exs` remains about 1,800 lines as a broad integration harness.

The remaining file still appears to own detailed cases that now have extracted module owners:

- pre-start command behavior;
- protocol partial-line and malformed JSON behavior;
- approval/input request policy;
- dynamic tool result behavior;
- sandbox and proxy propagation;
- remote SSH launch.

A process integration harness should prove the port loop wires these pieces together, not duplicate every boundary's unit matrix.

## Scope

- Identify cases already covered by startup/protocol/tool request/dynamic tool policy tests.
- Keep one integration case per major port-loop behavior.
- Move duplicated detailed matrices to boundary-owned tests.
- Extract fake Codex script generation into explicit test support if it remains needed.

## Out of Scope

- Removing app-server integration coverage entirely.
- Changing app-server behavior.
- Changing fake Codex protocol semantics.
- Combining this with production code refactors.

## Acceptance Criteria

- `app_server_test.exs` is process-focused and materially smaller.
- Detailed protocol/tool/startup cases live with their owning modules.
- No assertion is deleted without equivalent coverage elsewhere.
- The fake executable harness is understandable and not copied across files.

## Verification

- `mix test test/symphony_elixir/app_server_test.exs`
- `mix test test/symphony_elixir/codex_startup_test.exs`
- `mix test test/symphony_elixir/codex/protocol_test.exs`
- `mix test test/symphony_elixir/codex/tool_request_handler_test.exs`
- `rg -n "pre-start|partial JSON|malformed|auto-approves|requestUserInput|dynamic tool|remote workers" test/symphony_elixir/app_server_test.exs test/symphony_elixir`
- `mix exec_plans.check`

