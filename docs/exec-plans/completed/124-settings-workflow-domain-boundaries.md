# 124 Settings Workflow Domain Boundaries

## Goal

Extract workflow settings form/domain responsibilities out of `AdminLive` and `WorkflowForm` so new workflow fields do not require touching giant mixed-responsibility modules.

## Status

Completed.

## Background

Settings is no longer a raw textarea, but the workflow contract remains concentrated in large UI/form modules:

- `AdminLive` owns rendering, event handling, import/export UI, validation display, history, and diagnostics summaries.
- `WorkflowForm` owns a large draft map, parsing, serialization, turn sandbox handling, profile routing fields, and validation errors.

Long-term docs say Settings should cover the full runtime contract with field, section, and contract validation. Continuing to add fields directly to these modules will make that harder.

## Scope

- Define a workflow settings domain boundary separate from LiveView rendering.
- Split parseable field validation from runtime contract validation.
- Move import/export/diff preparation out of `AdminLive` where practical.
- Pick one concrete slice first, such as import/export mapping or validation summary ownership.

## Out of Scope

- Full Settings redesign.
- Replacing Phoenix LiveView.
- Changing workflow package format.
- Implementing every missing workflow field.

## Acceptance Criteria

- At least one cohesive Settings workflow responsibility leaves `AdminLive` or `WorkflowForm`.
- The extracted module has focused tests.
- New workflow fields have a clearer owner than a giant draft map plus LiveView handlers.
- Existing Settings save/import tests pass.

## Test Cases

- Existing `web_fake_persistence_test`.
- Existing workflow form tests.
- New focused tests for the extracted boundary.

## Implementation Notes

Extract one real responsibility and delete the old code path. Do not add a facade that leaves all decisions in `AdminLive`.

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

- Completed plan 081.
- Completed plan 110.
- Completed plan 115.

## Handoff Notes

This is the AdminLive-specific large-module slice. Keep Orchestrator/AppServer/Workspace extractions in their own plans.
