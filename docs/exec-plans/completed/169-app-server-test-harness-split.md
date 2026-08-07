# 169 App Server Test Harness Split

## Goal

Split `test/symphony_elixir/app_server_test.exs` into protocol, startup, policy, and remote-launch test files.

## Status

Completed.

## Background

`app_server_test.exs` is still about 1,800 lines. It covers:

- startup failure and timeout context;
- pre-start command execution;
- workspace path safety;
- sandbox policy propagation;
- proxy environment;
- input-required and approval handling;
- dynamic tool calls;
- protocol line buffering and malformed events;
- remote SSH launch.

The implementation has already extracted startup, protocol, and tool request boundaries. Keeping all tests in one file hides the new ownership and keeps every app-server change expensive to review.

## Scope

- Move startup command/error tests to startup-focused files.
- Move protocol buffering/malformed JSON tests to protocol tests.
- Move approval/input/dynamic tool request tests to tool request handler tests.
- Keep one thin integration test file for `Codex.AppServer` port lifecycle.
- Preserve fake executable harnesses only where integration tests still need them.

## Out of Scope

- Changing app-server behavior.
- Removing integration coverage.
- Replacing fake Codex scripts with a new framework.
- Changing tool policy semantics.

## Acceptance Criteria

- Each extracted implementation boundary has nearby tests.
- The remaining app-server integration test file is materially smaller and process-focused.
- Existing app-server behavior remains covered.
- Test failures point to the relevant boundary instead of the whole app-server surface.

## Verification

- `mix test test/symphony_elixir/app_server_test.exs`
- `mix test test/symphony_elixir/codex`
- `rg -n "buffers partial JSON|malformed|approval|required|dynamic tool|pre-start|remote workers" test/symphony_elixir`
- `mix exec_plans.check`

## Completion Deviations

Focused Codex protocol, startup, tool request handler, and dynamic tool policy tests are present and were extended by this work. The legacy `app_server_test.exs` remains as the process-level integration harness; no assertions were removed.
