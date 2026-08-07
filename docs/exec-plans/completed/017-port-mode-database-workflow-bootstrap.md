# Task 017: Port Mode Database Workflow Bootstrap

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 002, Task 003, Task 005
**Created**: 2026-05-01

## Goal

Allow Symphony to start in port/dashboard mode with SQLite available even when `WORKFLOW.md` is missing, as long as an active workflow version already exists in the database.

## Background

The current startup model still assumes a file-backed `WORKFLOW.md` unless database workflow loading is explicitly enabled. Long term, the Panel should be able to run as a web service backed by SQLite, where configuration is stored in the database and managed through the UI.

This matters for deployments where operators want to start the service first, open the Web UI, and manage workflow configuration from the database instead of editing a file on disk.

## Scope

- Detect dashboard/port mode when `--port` or `server.port` is configured.
- When SQLite is available and an active database workflow exists, allow startup without a file `WORKFLOW.md`.
- Load active workflow from `workflow_versions` before attempting file fallback in this mode.
- Keep file-backed startup behavior for non-port CLI runs unless explicitly configured otherwise.
- Return clear errors when neither file workflow nor active database workflow exists.
- Ensure this works with the existing `WorkflowStore` cache.

## Out of Scope

- Building the UI flow for creating the first workflow. That belongs to Task 018.
- Removing file-backed workflow support.
- Supporting multiple active workflows per project.
- Changing worker execution mode behavior.

## Acceptance Criteria

- [ ] `--port` mode can boot without `WORKFLOW.md` if SQLite has an active workflow version.
- [ ] Non-port CLI mode still defaults to file-backed `WORKFLOW.md`.
- [ ] If no file and no active database workflow exists, startup error clearly says configuration must be created or imported.
- [ ] Existing file-backed hot reload behavior remains unchanged.
- [ ] The active DB workflow is validated with existing config schema before use.

## Test Cases

- Start with `--port`, missing `WORKFLOW.md`, active DB workflow exists, service boots.
- Start without `--port`, missing `WORKFLOW.md`, active DB workflow exists, behavior follows explicit config only.
- Start with `--port`, missing `WORKFLOW.md`, no DB workflow, service exposes or reports a setup-required state.
- Invalid active DB workflow is rejected.
- Existing workflow file tests continue passing.

## Implementation Notes

- Prefer an explicit source mode such as `:database_or_file` or `:port_database_or_file` instead of hidden behavior inside arbitrary file loading.
- Avoid silently creating placeholder workflow records.
- Keep error messages operator-facing and actionable.
- Do not require a Rust worker or worker mode for this behavior.

## Verification

- `mise exec -- mix test test/symphony_elixir/workflow_store_test.exs`
- `mise exec -- mix test test/symphony_elixir/cli_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Implemented `:database_or_file` workflow source mode.
- CLI now enables database-or-file mode when started with `--port` and no explicit workflow path.
- If both file and active DB workflow are missing, WorkflowStore provides a setup-required memory workflow so the dashboard can boot.

## Dependencies

- SQLite persistence from Task 002.
- Database workflow loading from Task 003.
- Web UI workflow management from Task 005.

## Handoff Notes

- Record the final workflow source precedence rule.
- Record whether `--port` automatically enables DB fallback or whether a config flag is required.
- Record how setup-required state is represented if no workflow exists.
