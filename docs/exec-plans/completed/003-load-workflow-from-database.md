# Task 003: Load Workflow From Database

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 002
**Created**: 2026-05-01

## Goal

Move workflow loading from file-only `WORKFLOW.md` to database-backed workflow versions while preserving import/export compatibility with the existing file format.

## Background

The long-term direction requires the entire `WORKFLOW.md` contract to be configurable. That includes YAML front matter and Markdown prompt body, not only the prompt text.

The database should store complete workflow versions so each run can be tied to the exact workflow configuration that created it. This is required for auditability, debugging, rollback, and future Web UI editing.

## Scope

- Store complete workflow versions in SQLite.
- Preserve the raw `WORKFLOW.md` text.
- Store parsed YAML config and prompt body separately.
- Add import from `WORKFLOW.md` into the database.
- Add export from active workflow version back to `WORKFLOW.md` format.
- Update `WorkflowStore` so the active workflow can come from SQLite.
- Preserve file-based startup as a migration/bootstrap path.
- Add workflow version validation using existing config/schema parsing.

## Out of Scope

- Full Web UI editing. That belongs to Task 005.
- Runtime state persistence. That belongs to Task 004.
- Multi-project tracker dispatch. That belongs to Task 006.

## Acceptance Criteria

- [ ] A complete workflow can be imported from an existing `WORKFLOW.md`.
- [ ] The active workflow can be loaded from SQLite.
- [ ] The raw workflow Markdown can be exported without losing YAML front matter or prompt body.
- [ ] Invalid workflow YAML/config is rejected before becoming active.
- [ ] Each workflow version records created timestamp and active/inactive status.
- [ ] Existing CLI behavior remains usable for bootstrap and local development.
- [ ] Tests cover file import, database load, invalid workflow rejection, and export.

## Test Cases

- Import current `elixir/WORKFLOW.md` into a new workflow version.
- Import preserves raw Markdown exactly enough for export compatibility.
- Parsed YAML front matter and prompt body match the imported file.
- Active workflow can be loaded from SQLite by `WorkflowStore`.
- Invalid YAML is rejected and does not replace the active workflow.
- Invalid config schema is rejected and does not replace the active workflow.
- Export reconstructs a valid `WORKFLOW.md` with front matter and prompt body.
- Activating an older workflow version changes the active runtime source.
- File-based bootstrap seeds the database when no active workflow exists.
- Explicit CLI workflow path behavior follows the chosen precedence rule.

## Implementation Notes

- Treat `WORKFLOW.md` as a serializable workflow contract.
- Do not split only the prompt into the database; the YAML front matter must be part of the version.
- The active workflow version should be immutable after creation. Editing creates a new version.
- Keep backward compatibility: a fresh install should be able to seed the DB from a file.
- Consider a clear precedence rule: explicit CLI workflow path can seed or override depending on selected mode.

## Verification

- Focused tests for workflow import/export.
- Focused tests for `WorkflowStore` loading from SQLite.
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test`
- Manual check: import current `elixir/WORKFLOW.md`, start service, verify existing orchestration config is visible and active.

## Completion Deviations

- Database-backed workflow loading is explicit via `:workflow_source, :database` during the migration period.
- File-backed `WORKFLOW.md` remains the default to preserve existing hot-reload behavior and compatibility.
- Export uses the stored raw workflow when available; generated YAML export is a conservative serializer for supported workflow values.

## Handoff Notes

- Record the final precedence rule between CLI workflow path, active DB workflow, and default file.
- Record any compatibility limitations in import/export.
- Record how rollback to a previous workflow version is expected to work.
