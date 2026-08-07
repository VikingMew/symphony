# 150 - Config Schema Runtime Resolution Boundary

Status: Completed

## Problem

`SymphonyElixir.Config.Schema` also owns runtime value resolution: secret/env token handling, path expansion, workspace root defaults, runtime sandbox defaults, and generated bootstrap/before-remove command construction.

These are not the same concern as schema definition or workflow contract validation. Keeping runtime resolution in the schema module makes it easy for docs, UI package import, and runtime defaults to drift.

## Goal

Extract runtime resolution and generated command construction into one or more focused modules, for example:

- `SymphonyElixir.Config.RuntimeResolver`
- `SymphonyElixir.Config.ProjectCommands`

The schema module should apply resolved values, not own every resolution rule.

## Plan

1. Inventory helpers for env/secret/path resolution, sandbox policy defaults, workspace root defaults, and generated project commands.
2. Split pure command construction from runtime/environment resolution if they have different test needs.
3. Add focused tests for `$ENV` references, blank values, path expansion, local/remote sandbox defaults, generated clone commands, and worktree behavior.
4. Delegate from `Config.Schema` without changing public parsed settings shape.
5. Ensure approval-policy handling remains aligned with plan 137.
6. Re-run schema and workflow package tests to catch drift.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/config/runtime_resolver_test.exs test/symphony_elixir/config/project_commands_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/workflow_settings_package_test.exs`
  - Result: `71 tests, 0 failures`.
- `rg -n "resolve_secret|resolve_env|resolve_path|default_turn_sandbox|generated_project_bootstrap|generated_before_remove|maybe_append_source_command|env_secret|default_workspace_root|expand_local_workspace_root" lib/symphony_elixir/config test/symphony_elixir/config test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/workflow_settings_package_test.exs`
  - Result: runtime/env/path/sandbox helpers now live in `Config.RuntimeResolver`; generated project commands now live in `Config.ProjectCommands`; `Config.Schema` retains only public compatibility wrappers and parse-time delegation.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

`Config.Schema.generated_project_bootstrap_commands/1`, `project_setup_commands/1`, `generated_before_remove_hook/1`, and sandbox resolver public functions remain as stable public entry points. Their implementation now delegates to the extracted modules.
