# Task 018: Create Workflow from Empty Database in UI

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 005, Task 017
**Created**: 2026-05-01

## Goal

Let an operator create the first project/workflow configuration from the Web UI when the service is running in port/dashboard mode with SQLite but no `WORKFLOW.md`.

## Background

If port mode can boot without a workflow file, the UI must provide a practical setup path. Otherwise the service can start but cannot become useful without manual database writes or importing a file.

The initial UI can be simple. It does not need a full structured workflow builder in the first pass, but it must allow creating a valid active workflow version.

## Scope

- Add an empty-state setup view on `/workflows` when no active workflow exists.
- Allow creating the first workflow version from raw `WORKFLOW.md` text pasted into the UI.
- Optionally provide a minimal starter template in the textarea.
- Ensure saving validates YAML front matter and config schema before activation.
- Ensure the created workflow becomes active and is immediately usable by `WorkflowStore`.
- Keep import/export compatibility with existing raw workflow storage.

## Out of Scope

- Full field-by-field structured workflow editor.
- Secret management UI.
- Multi-project setup wizard.
- Automatically discovering Linear projects.

## Acceptance Criteria

- [ ] `/workflows` renders a setup state when no active workflow exists.
- [ ] User can paste or edit raw workflow content and save it as version 1.
- [ ] Invalid YAML/config is rejected with a visible error.
- [ ] Successful save creates an active workflow version in SQLite.
- [ ] After save, dashboard pages can read the active database workflow.
- [ ] Existing workflow version history UI still works.

## Test Cases

- Render `/workflows` with empty DB and no file workflow.
- Save a valid raw workflow from the setup state.
- Save invalid YAML and verify no active workflow is created.
- Save invalid config and verify no active workflow is created.
- Verify version history shows the newly created version.
- Verify `WorkflowStore.current/0` can load the new active workflow in DB mode.

## Implementation Notes

- Reuse `Persistence.import_workflow/3`.
- Keep the first pass raw-editor based.
- Label the source as `web_setup` or similar.
- Avoid writing a new `WORKFLOW.md` file as a side effect.
- Do not require the dashboard to be unauthenticated; respect existing auth settings.

## Verification

- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_ui_setup_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- `/workflows` now renders a setup message and starter raw workflow when no active workflow/file exists.
- First workflow creation reuses the existing raw workflow import path and stores a database-backed active version.
- Structured field-by-field creation remains future work.

## Dependencies

- Web workflow page from Task 005.
- Port mode DB bootstrap from Task 017.

## Handoff Notes

- Record the exact setup source value stored in `workflow_versions.source`.
- Record whether a starter template is included.
- Record any fields still requiring raw YAML editing.
