# 121 Dynamic Atom Conversion Cleanup

## Goal

Remove unbounded runtime `String.to_atom/1` usage and make mixed atom/string payload access use `SymphonyElixir.Payload` or explicit closed whitelists.

## Status

Completed.

## Background

`SymphonyElixir.Payload` now owns mixed atom/string keyed external payload access. Remaining production paths still contain local atom conversion:

- `StatusDashboard.raw_value/2` uses `String.to_atom(key)`;
- `Codex.DynamicTool` uses `String.to_atom(field)` for update arguments;
- `HttpServer.raw_server_value/1` uses `String.to_existing_atom(key)` with rescue;
- `RunHistory.normalize_codex_event/1` uses `String.to_existing_atom/1` with rescue.

The main risk is not every existing call site equally. The problem is that atom/string compatibility is no longer centralized, and one production path can still create atoms dynamically.

## Scope

- Replace production `String.to_atom/1` call sites with `Payload.get_any/3` or fixed whitelists.
- Review `String.to_existing_atom/1` call sites and keep them only for closed internal enums.
- Add a test or static check that prevents new production `String.to_atom/1`.
- Preserve existing payload behavior.

## Out of Scope

- Rewriting all payload handling.
- Changing persisted event shapes.
- Changing Codex dynamic tool public arguments.

## Acceptance Criteria

- No production `String.to_atom/1` remains in `lib/`.
- Any remaining `String.to_existing_atom/1` has a documented closed-vocabulary reason.
- Mixed key lookup uses `SymphonyElixir.Payload` or an explicit whitelist.
- Existing dynamic tool, status dashboard, HTTP server, and run history tests pass.

## Test Cases

- Static check rejects `String.to_atom(` under `lib/`.
- Existing `state_name_payload_test`.
- Existing `dynamic_tool_test`.
- Existing status/run history tests.
- Existing HTTP/server tests that cover config reads.

## Implementation Notes

Do not replace atom creation with broad `rescue` blocks. Make allowed keys explicit.

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

- Completed plan 112.

## Handoff Notes

This is a small cleanup with a clear deletion target. Keep it separate from broader payload refactors.
