# 198 Dynamic Tool Issue Create Boundary

## Goal

Extract the `linear_issue_create` execution path out of the main `Codex.DynamicTool` module into a focused boundary with explicit policy, input, and response normalization.

## Status

Completed.

## Background

`lib/symphony_elixir/codex/dynamic_tool.ex` is now roughly 769 lines. Completed plan 167 split dynamic-tool policy, but the module has since grown to include issue creation for nap/day-dreaming flows:

- issue-create argument normalization;
- profile validation;
- team/state lookup;
- description construction;
- Linear create input shaping;
- response normalization.

This mixes task read/update tool behavior with a separate creation workflow. It makes policy reasoning harder and encourages another large conditional module.

## Scope

- Move issue-create-specific code into a focused module such as `Codex.DynamicTool.IssueCreate`.
- Keep the public tool execution contract stable.
- Keep policy checks explicit and close to the issue-create boundary.
- Preserve task read/update behavior in the existing dynamic-tool path or its current helper modules.
- Add focused tests for issue-create normalization, policy rejection, and success response shape.

## Out of Scope

- Changing which profiles can create Linear issues.
- Changing the issue description prompt or product semantics.
- Changing task read/update tool behavior.
- Replacing Linear client APIs.

## Acceptance Criteria

- `Codex.DynamicTool` no longer owns issue-create input assembly or response normalization directly.
- The issue-create module has a narrow public API and can be tested without exercising unrelated task update paths.
- Task read/update tests still pass unchanged.
- Nap/day-dreaming issue creation still receives the same allowed profile behavior and response shape.
- The split reduces `Codex.DynamicTool` line count for an ownership reason, not by moving random helpers.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/app_server_tool_policy_test.exs`
- `wc -l lib/symphony_elixir/codex/dynamic_tool.ex lib/symphony_elixir/codex/dynamic_tool/*.ex`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 167 for dynamic tool policy boundary.
- Completed plan 186 for nap Linear issue creation tool.

## Handoff Notes

Keep the split centered on tool semantics. The main module should dispatch; the new boundary should own creating a Linear issue from trusted tool arguments.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

