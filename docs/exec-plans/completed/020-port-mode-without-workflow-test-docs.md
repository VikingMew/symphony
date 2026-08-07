# Task 020: Port Mode Without WORKFLOW.md Tests and Docs

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 017, Task 018, Task 019
**Created**: 2026-05-01

## Goal

Add end-to-end tests and user documentation for running Symphony in port/dashboard mode with SQLite and no initial `WORKFLOW.md`.

## Background

The no-file port-mode path changes the first-run user experience. It must be documented clearly so users know when `WORKFLOW.md` is optional, when it is still required, and how to create or import workflow configuration from the UI.

## Scope

- Add focused integration tests for missing `WORKFLOW.md` in port mode.
- Add docs for starting with SQLite and dashboard only.
- Add docs for creating the first workflow from `/workflows`.
- Add troubleshooting docs for missing active workflow, invalid workflow, and DB unavailable.
- Update README examples to distinguish file-first and DB-first startup.

## Out of Scope

- Browser automation beyond existing LiveView/controller tests unless needed.
- Production deployment guide for systemd/Docker.
- Full structured workflow editor docs.

## Acceptance Criteria

- [ ] README explains file-first and DB-first startup modes.
- [ ] Chinese user guide explains how to start with `--port` and create workflow from UI.
- [ ] Tests cover missing file with active DB workflow.
- [ ] Tests cover missing file with empty DB setup state.
- [ ] Troubleshooting covers DB unavailable and no active workflow.
- [ ] Existing `WORKFLOW.md` startup examples remain valid.

## Test Cases

- Start endpoint/dashboard with DB available and no workflow file.
- Visit `/workflows` and see setup state.
- Create workflow from UI and verify it becomes active.
- Restart workflow store and verify DB workflow is selected.
- Attempt start with DB unavailable and no file, verify actionable error.

## Implementation Notes

- Keep docs precise about when `WORKFLOW.md` is optional.
- Avoid implying worker mode is required.
- Include migration path from existing file workflow to DB workflow.
- Keep command examples compatible with mise.

## Verification

- `mise exec -- mix test test/symphony_elixir/*workflow*_test.exs`
- `mise exec -- mix test test/symphony_elixir/*web*_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Added CLI, WorkflowStore, and LiveView tests for database-or-file and first-workflow setup flows.
- Updated README, Chinese user guide, and persistence/auth docs.
- Browser automation was not added; existing controller/LiveView coverage verifies the flow.

## Dependencies

- Startup behavior from Task 017.
- UI creation flow from Task 018.
- Precedence rule from Task 019.

## Handoff Notes

- Record final README section names.
- Record whether no-file port mode requires an environment variable.
- Record any manual verification commands.
