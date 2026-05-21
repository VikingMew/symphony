# 120 Legacy Workflow Compatibility Boundary

## Goal

Stop hidden legacy workflow compatibility from leaking through runtime parsing. Stale package shapes should be normalized only at explicit import/sanitize boundaries or rejected with actionable errors.

## Status

Completed.

## Background

The long-term direction says alpha-stage development should not preserve hidden compatibility paths. Current behavior still tolerates legacy shapes:

- object-form `codex.approval_policy.reject` is normalized to `never`;
- stale workflow-owned `tracker.api_key` is ignored while `LINEAR_API_KEY` is used.

Tolerance may be useful for importing old data, but it should not remain an implicit runtime contract.

## Scope

- Classify legacy `approval_policy.reject` and stale `tracker.api_key` handling as import cleanup, runtime tolerance, or rejection.
- Move any retained tolerance to explicitly named import/sanitize code paths.
- Ensure new saves and exports never contain legacy approval maps or workflow-owned tracker tokens.
- Add removal conditions for any stale parser tolerance that remains.

## Out of Scope

- Adding a general migration framework.
- Changing the `LINEAR_API_KEY` env-only runtime source.
- Supporting arbitrary old Codex app-server protocol shapes.

## Acceptance Criteria

- Runtime active workflow parsing does not silently preserve legacy shapes without an owner and removal condition.
- Importing old package data either normalizes once into the current contract or fails clearly.
- Saved/exported workflow packages cannot contain `codex.approval_policy.reject`.
- Saved/exported workflow packages cannot contain workflow-owned `tracker.api_key`.

## Test Cases

- Import old `reject` approval shape and verify the saved workflow uses the current string enum or rejects import.
- Save/export a workflow and assert no `reject` approval map appears.
- Save/export a workflow and assert no `tracker.api_key` appears.
- Runtime parse tests document whether old shapes are rejected or accepted only through sanitize/import.

## Implementation Notes

Prefer deletion over compatibility. If old data must be accepted, keep the acceptance narrow and visible.

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

- Completed plan 086.
- Completed plan 102.
- Completed plan 110.

## Handoff Notes

Do not make README say "legacy compatibility" while the long-term policy says "no hidden compatibility" unless the boundary and removal condition are explicit.
