# 126 Execplan Completion Evidence Governance

## Goal

Tighten completion evidence for user-facing and observability exec plans so completed plans do not pass on unit-level evidence while real operator behavior remains weak.

## Status

Completed.

## Background

Active plan 118 exists because completed plan 116 improved run detail readability, but a real run still showed low-signal `codex.update` rows and missing agent-turn detail.

That is a process smell: for operator-facing work, unit-level transformation tests are not always enough evidence that the delivered page answers the user's question.

## Scope

- Define completion evidence expectations for user-facing and observability plans.
- Require rendered UI output, realistic event fixtures, screenshots, or equivalent operator-facing evidence when acceptance criteria are UI/observability oriented.
- Require linked follow-up plans when completion deviations leave high-priority acceptance criteria unmet.
- Decide whether any part belongs in `mix exec_plans.check` or only in documented review guidance.

## Out of Scope

- Re-opening plan 116.
- Implementing plan 118.
- Building a heavy process system around every plan.

## Acceptance Criteria

- Exec-plan guidelines describe stronger completion evidence for UI/observability work.
- Completed plans with unmet high-priority acceptance criteria must link an active follow-up.
- The rule is either mechanically checked where reliable or explicitly documented as review policy.

## Test Cases

- `mix exec_plans.check` if a mechanical rule is added.
- Existing exec-plan index tests.

## Implementation Notes

Avoid false confidence. Only automate what can be checked reliably; document the rest as a completion checklist.

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

- Completed plan 116.
- Active plan 118.

## Handoff Notes

This is process governance, not a substitute for fixing run detail signal in plan 118.
