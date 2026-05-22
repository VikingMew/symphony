# 206 App Server Tool Policy Test Split

## Goal

Split `app_server_tool_policy_test.exs` into focused policy suites for tool visibility, permission decisions, startup state, and dynamic-tool integration.

## Status

Completed.

## Background

`test/symphony_elixir/codex/app_server_tool_policy_test.exs` is roughly 950 lines. It covers several distinct policy behaviors around app-server tool exposure and dynamic-tool availability.

The production app server and dynamic-tool policy boundaries have been split, but this test file still groups too many independent contracts together.

## Scope

- Inventory test groups by policy responsibility.
- Move one coherent policy group into a dedicated test file.
- Keep app-server harness setup reusable but narrow.
- Preserve existing assertions and fixtures.
- Coordinate with completed plan 198 when issue-create policy moves out of `DynamicTool`.

## Out of Scope

- Changing app-server startup behavior.
- Changing tool policy semantics.
- Replacing the app-server test harness.
- Rewriting dynamic-tool tests.

## Acceptance Criteria

- `app_server_tool_policy_test.exs` loses at least one complete policy group.
- New test file names describe the policy contract under test.
- Shared setup stays explicit and does not hide policy inputs.
- Existing app-server and dynamic-tool policy tests pass.
- Future changes to issue-create policy have a focused test target.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/app_server_tool_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/app_server_*_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_policy_test.exs`
- `wc -l test/symphony_elixir/codex/app_server_tool_policy_test.exs test/symphony_elixir/codex/app_server_*_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 167 for dynamic tool policy boundary.
- Completed plan 169 for app server test harness split.
- Completed plan 179 for app server integration harness thinning.
- Completed plan 198 for dynamic tool issue-create boundary.

## Handoff Notes

The useful split follows policy ownership. Do not move assertions just to reduce line count.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

