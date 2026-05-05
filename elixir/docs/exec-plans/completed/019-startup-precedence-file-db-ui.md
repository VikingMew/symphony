# Task 019: Startup Precedence for File, Database, and UI Workflows

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 017, Task 018
**Created**: 2026-05-01

## Goal

Define and implement a clear workflow source precedence rule across explicit CLI files, database-backed workflows, and UI-created workflows.

## Background

Symphony now supports both file-backed `WORKFLOW.md` and database workflow versions. Once port mode can run without a workflow file, ambiguous precedence becomes dangerous. Operators need predictable behavior:

- When does a CLI path override the database?
- When is the database authoritative?
- When does a file seed the database?
- When can the UI-created workflow become active runtime config?

## Scope

- Define workflow source modes and precedence rules.
- Update CLI behavior to avoid accidentally overwriting active DB workflows.
- Ensure explicit CLI file path still works for traditional local runs.
- Ensure port/dashboard mode can prefer DB workflow when available.
- Document how file import, DB activation, and UI creation interact.
- Add clear logs for chosen workflow source at startup.

## Out of Scope

- Removing `WORKFLOW.md`.
- Full multi-project runtime workflow selection.
- Secret migration from file YAML to secret references.

## Acceptance Criteria

- [ ] Precedence rule is documented in README/user guide.
- [ ] Explicit CLI workflow path behavior is deterministic.
- [ ] Port mode with active DB workflow does not require file workflow.
- [ ] File-backed mode remains available.
- [ ] UI-created active workflow can become runtime source without writing a file.
- [ ] Startup logs identify the selected workflow source.

## Test Cases

- Explicit CLI file path with file source mode uses that file.
- Port mode with active DB workflow uses DB when file is missing.
- Port mode with active DB workflow and file present follows documented precedence.
- UI-created workflow becomes active and is selected in DB-preferred mode.
- File import does not overwrite active DB workflow unless explicitly requested.

## Implementation Notes

- Prefer explicit modes such as `file`, `database`, and `database_or_file`.
- Avoid relying only on whether `--port` is present if that makes behavior surprising.
- If `--port` enables DB fallback, log that decision clearly.
- Keep old behavior available for scripts and local development.

## Verification

- `mise exec -- mix test test/symphony_elixir/cli_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_store_test.exs`
- `mise exec -- mix test`

## Completion Deviations

- Final implemented modes are file-backed default, explicit `:database`, and `:database_or_file`.
- Non-port CLI without an explicit DB source still requires `WORKFLOW.md`.
- Port mode with no explicit workflow path allows DB workflow or UI setup; explicit workflow paths still require the file.

## Dependencies

- Port mode DB bootstrap from Task 017.
- UI workflow creation from Task 018.

## Handoff Notes

- Record final source mode names.
- Record final behavior for explicit CLI path plus active DB workflow.
- Record any compatibility warning added for old startup flows.
