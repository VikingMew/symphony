# 123 Coverage Ignore Exit Slices

## Goal

Turn the governed coverage ignore list into per-module exit work so high-risk runtime behavior does not stay outside coverage indefinitely.

## Status

Completed.

## Background

Plan 114 grouped ignored modules and added removal conditions. The ignore list is now governed, but it still excludes core behavior such as:

- `Orchestrator`;
- `AgentRunner`;
- `Codex.AppServer`;
- `Codex.DynamicTool`;
- `Workspace`;
- `Persistence`;
- `StatusDashboard` and LiveView/controller shells.

The next step is not another broad governance note. Each ignored module or family needs an exit slice.

## Scope

- Add per-module or per-family removal slices to coverage governance.
- Identify the first ignored runtime module that can exit via focused behavior tests.
- Keep helper/pure modules out of the ignore list by default.
- Preserve the 85% threshold unless evidence supports changing it separately.

## Out of Scope

- Covering every ignored module in one change.
- Raising the global threshold.
- Adding superficial tests only to inflate line coverage.

## Acceptance Criteria

- Every ignored module has a reason and a next removal slice or permanent rationale.
- At least one core runtime module exits `ignore_modules`.
- Governance distinguishes process-boundary ignores from missing-test debt.
- `mix test --cover` remains green.

## Test Cases

- `coverage_ignore_governance_test`.
- Focused tests for the first module removed from `ignore_modules`.
- `mix test --cover`.

## Implementation Notes

Prefer removing one ignored module with meaningful tests over annotating many modules more heavily.

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

- Completed plan 106.
- Completed plan 114.

## Handoff Notes

Good first candidates are small boundaries extracted from ignored modules, not the entire process modules themselves.
