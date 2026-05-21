# 125 App Server Startup Boundary

## Goal

Extract Codex app-server startup command composition and startup error classification out of `Codex.AppServer`.

## Status

Completed.

## Background

`Codex.AppServer` owns multiple unrelated responsibilities: startup shell composition, app-server protocol transport, turn lifecycle, dynamic tool handling, update parsing, and startup error shaping.

Startup command construction and startup failure classification are relatively pure boundaries with clear tests. They are good extraction candidates before touching protocol or process ownership.

## Scope

- Extract startup command/script construction into a focused module.
- Extract startup error classification/sanitization if it can be done without changing behavior.
- Preserve pre-start command semantics, shell escaping, cwd handling, and redaction.
- Add direct tests for the extracted boundary.

## Out of Scope

- Changing Codex app-server protocol messages.
- Changing turn lifecycle behavior.
- Changing sandbox or approval policy defaults.
- Rewriting process supervision.

## Acceptance Criteria

- `Codex.AppServer` no longer owns startup script composition directly.
- Startup command behavior remains byte-for-byte compatible where compatibility matters.
- Startup errors remain sanitized and actionable.
- Existing app-server tests pass.

## Test Cases

- Existing `app_server_test`.
- Focused startup command builder tests.
- Focused startup error classifier tests if extracted.

## Implementation Notes

Keep the extracted module small. It should produce command data and classified errors, not know how to run turns.

## Verification

- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/dynamic_atom_usage_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_cleanup_policy_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/coverage_ignore_governance_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_startup_test.exs test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_update_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_source_preparation_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix test --cover` (418 tests, 0 failures, 2 skipped, total coverage 85.72%)
- `mise exec -- mix lint`

## Completion Deviations

None.

## Dependencies

- Completed plan 101.
- Completed plan 110.
- Completed plan 112.

## Handoff Notes

This is the AppServer-specific large-module slice. Do not bundle it with turn protocol changes.
