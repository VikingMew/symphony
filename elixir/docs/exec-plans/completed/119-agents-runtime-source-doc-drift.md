# 119 AGENTS Runtime Source Doc Drift

## Goal

Fix the local contributor instructions so they describe the current runtime source of truth accurately: the SQLite active workflow version, not file-backed `workflow.yml` / `profiles.yml`.

## Status

Completed.

## Background

`elixir/AGENTS.md` still says file-backed runtime config is loaded through `SymphonyElixir.Workflow` and `SymphonyElixir.Config` using `workflow.yml` and `profiles.yml`.

That conflicts with the current contract in `ARCHITECTURE.md`, `elixir/README.md`, `docs/user_guide.zh-CN.md`, and DB-only tests: local split package files are import/export examples, while runtime reads the SQLite active workflow version.

## Scope

- Update `elixir/AGENTS.md` runtime-source wording.
- Keep `workflow.yml` and `profiles.yml` described as import/export/example artifacts.
- Preserve the instruction to use `SymphonyElixir.Config` for runtime access.
- Add a small consistency check only if the wording keeps drifting.

## Out of Scope

- Changing runtime behavior.
- Changing workflow import/export semantics.
- Editing unrelated docs.

## Acceptance Criteria

- `AGENTS.md` no longer implies local package files are the live runtime source.
- The wording agrees with `ARCHITECTURE.md`, `README.md`, `docs/user_guide.zh-CN.md`, and setup-required tests.
- Contributors are directed to runtime config through `SymphonyElixir.Config`.

## Test Cases

- `mix exec_plans.check`
- Targeted doc consistency check if one is added.

## Implementation Notes

Keep this as a documentation correction. Do not reintroduce file fallback language.

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

- Completed plan 080.
- Completed plan 086.

## Handoff Notes

This is the smallest and safest first slice because it removes misleading local instructions without touching runtime code.
