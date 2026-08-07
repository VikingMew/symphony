# 060 Workflow Hooks Config UI

## Goal

Expose lifecycle hook configuration in the Workflow page as structured fields, so operators can see, edit, validate, and remove hooks that affect runtime behavior.

## Status

Completed.

## Background

The workflow database can contain `hooks.after_create`, `hooks.before_run`, `hooks.after_run`, `hooks.before_remove`, and `hooks.timeout_ms`. These fields are part of the runtime config schema, but the Workflow page currently has no structured controls for them.

This creates a hidden-runtime-config problem: a workflow can display the correct target repository and project settings while a preserved `hooks.after_create` still runs stale bootstrap commands. Because the form preserves `_base_config`, hidden hooks can remain active after saving through the UI.

Hooks are still useful and should remain supported, but they need to be visible and editable in the same operator surface as repository bootstrap and profile routing.

## Scope

- Add structured Workflow page controls for:
  - `hooks.after_create`
  - `hooks.before_run`
  - `hooks.after_run`
  - `hooks.before_remove`
  - `hooks.timeout_ms`
- Load existing hook values from the active workflow into the form.
- Save hook values back into the workflow config.
- Allow operators to clear a hook field so the saved config no longer preserves stale commands.
- Validate `hooks.timeout_ms` as a positive integer when present.
- Keep hook textareas visibly separate from structured project bootstrap commands, with copy that makes their execution role clear.
- Add tests that saving the Workflow form preserves edited hooks and removes hooks that were cleared.

## Out of Scope

- Changing hook execution order. That is covered by plan 059.
- Adding a shell command linter or full script sandbox policy.
- Adding hook history, audit diff, or execution logs to the Workflow page.
- Supporting legacy compatibility behavior where `hooks.after_create` replaces project bootstrap.

## Acceptance Criteria

- [x] The Workflow page shows all configured lifecycle hook fields.
- [x] A workflow imported from a file or existing database row with hooks displays those hooks in the form.
- [x] Editing a hook and saving persists the edited hook value.
- [x] Clearing a hook and saving removes that hook from the effective saved config.
- [x] `hooks.timeout_ms` accepts positive integers and rejects invalid values with a field-specific validation error.
- [x] Existing project bootstrap fields remain unchanged by hook-only edits.
- [x] Tests cover hook load, save, clear, and timeout validation behavior.
- [x] Relevant test suite passes.

## Test Cases

- Active workflow contains `hooks.after_create`; opening the Workflow page renders the command in the `after_create` textarea.
- User clears `hooks.after_create` and saves; reloading the active workflow no longer contains `hooks.after_create`.
- User sets `hooks.before_run`, `hooks.after_run`, and `hooks.before_remove`; saved config contains the exact multiline values.
- User enters a non-integer or non-positive `hooks.timeout_ms`; the form rejects the save and shows a validation error.
- User changes only hook fields; `project.repository_url`, `project.setup_commands`, profiles, state routing, and base prompt are preserved.

## Implementation Notes

- Extend `SymphonyElixir.WorkflowForm` with hook fields and include them in `from_loaded/1`, `validate/1`, and `to_config/1`.
- Prefer omitting empty hook keys from the saved config instead of saving empty strings.
- Keep `hooks` as an optional map; do not require users to configure hooks.
- The UI should place hooks near Project Bootstrap because `after_create` interacts directly with repository setup.
- Add a short warning on the page that hooks execute shell commands in the workspace context and can affect runtime behavior.

## Verification

Passed:

- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- make all` progressed through setup, build, format check, lint, and coverage. Coverage ran 273 tests with 0 failures, 2 skipped, and 83.32% total coverage.

Known unrelated blocker:

- `mise exec -- make all` failed at the final Dialyzer step with existing repository warnings in modules such as `persistence.ex`, `orchestrator.ex`, `workflow.ex`, and `workflow_validator.ex`.

## Completion Deviations

The delivered UI saves `hooks.timeout_ms` with a default positive value even when all hook commands are empty. Cleared command fields are omitted from the saved hook map. `make all` is not fully green because Dialyzer currently reports existing project-wide warnings outside this plan.

## Dependencies

- Existing config schema support for `hooks`.
- Workflow form and LiveView save path.
- Plan 059 defines the desired execution order when both project bootstrap and `hooks.after_create` are present.

## Handoff Notes

This plan is intended to prevent hidden stale hook commands from surviving UI saves unnoticed. It does not replace plan 059; both are needed for the final operator contract.
