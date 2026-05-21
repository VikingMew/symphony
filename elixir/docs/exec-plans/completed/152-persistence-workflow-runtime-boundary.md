# 152 - Persistence Workflow Runtime Boundary

Status: Completed

## Problem

`SymphonyElixir.Persistence` also mixes workflow version import/export/activation and project runtime overlay logic with issue/run/event persistence.

Functions such as `import_workflow/3`, `active_workflow_version/1`, `workflow_to_loaded/1`, `apply_project_runtime_settings/2`, `activate_workflow_version/1`, and workflow version listing form a coherent workflow store boundary. Keeping them in the same module as worker queue and runtime event storage makes the context too broad.

## Goal

Extract workflow/project runtime persistence into a focused module such as `SymphonyElixir.Persistence.WorkflowStore`.

The boundary should own active workflow selection, version activation, workflow export, and project runtime overlay application.

## Plan

1. Inventory workflow/project persistence helpers in `persistence.ex`.
2. Move workflow import/export/activation and project runtime overlay logic into the new module.
3. Keep `Persistence` as a compatibility facade if the provider behavior expects it.
4. Add tests for default project fallback, active workflow selection, project overlay fields, test-source activation restrictions, and export round trips.
5. Ensure `WorkflowStore.current_with_source/0` and UI settings paths keep the same behavior.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/persistence/workflow_store_test.exs test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/workflow_settings_package_test.exs test/symphony_elixir/workspace_and_config_test.exs` - 112 tests, 0 failures
- `rg -n "import_workflow|active_workflow_version|workflow_to_loaded|apply_project_runtime_settings|activate_workflow_version|list_workflow_versions" lib test`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- Focused `WorkflowStore` tests intentionally avoid starting a real Repo, matching the current mocked persistence test boundary. Existing fake persistence and settings tests cover the web-facing workflow import/save contract.
