# Task 023: Workflow UI and Runtime Source Consistency

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 017, Task 018, Task 019, Task 021, Task 022
**Created**: 2026-05-01

## Goal

Make `/workflows`, `/diagnostics/linear`, and runtime orchestration use the same active workflow source, or clearly show when they intentionally do not.

Editing and activating a workflow from the Web UI must affect the Linear diagnostics page without requiring manual database writes, URL guessing, or ambiguous restarts.

## Root Cause

The current pages read workflow configuration through different paths:

- `/workflows` uses `Persistence.active_workflow_version()` first and shows the active SQLite workflow version.
- `/diagnostics/linear` uses `Config.settings()`, which calls `Workflow.current()`, which reads through `WorkflowStore`.
- `WorkflowStore` only reads SQLite when `Application.get_env(:symphony_elixir, :workflow_source)` is `:database`.
- If Symphony is started with an existing `WORKFLOW.md`, older CLI startup chose the file path first and did not set `:workflow_source` to `:database`.

That means a normal `--port` startup can show:

- `/workflows`: SQLite active workflow.
- `/diagnostics/linear`: file-backed `WORKFLOW.md` runtime workflow.

Saving in `/workflows` writes a new SQLite workflow version, but the Linear page keeps reading file-backed runtime config. From the user's perspective, the workflow page appears unable to modify the Linear page.

## Scope

- Add an explicit runtime workflow source model visible to the Web UI.
- Make `/workflows` show the exact workflow source currently used by runtime config.
- Make `/diagnostics/linear` show the exact workflow source used for its probes.
- Ensure saving or activating a workflow from `/workflows` refreshes `WorkflowStore`.
- Decide and implement the port-mode precedence rule for Web-managed deployments:
  - When running with `--port` and SQLite is available, Web UI saved workflows should become the runtime source.
  - Existing file-backed startup must remain supported for centralized/file-first deployments.
- Prevent `/workflows` from silently showing a DB workflow as if it were runtime active when runtime is actually using `WORKFLOW.md`.
- Add an operator-visible action or state transition to switch runtime from file-backed to database-backed workflow when appropriate.
- Add tests covering startup with both a file workflow and a DB active workflow.

## Out of Scope

- Removing file-backed `WORKFLOW.md` support.
- Full structured workflow editor.
- Multi-project runtime workflow selection.
- Editing Linear settings through a separate structured form.
- Restarting already-running agent turns after a workflow edit.

## Acceptance Criteria

- [x] `/workflows` displays `Runtime source: file`, `database`, or `setup_required`.
- [x] `/diagnostics/linear` displays the same runtime workflow source used by `Config.settings()`.
- [x] If `/workflows` is showing a SQLite active workflow that is not the runtime source, the UI clearly marks it as not currently used.
- [x] Saving a valid workflow through `/workflows` creates a new active DB workflow version.
- [x] In Web-managed port mode, saving or activating a DB workflow makes Linear diagnostics use that DB workflow immediately.
- [x] `WorkflowStore.force_reload/0` is called or otherwise triggered after workflow save/activation.
- [x] Existing explicit file-first startup remains supported and documented.
- [x] Tests prove that editing tracker `project_slug` in `/workflows` changes what `/diagnostics/linear` reads in DB-backed/Web-managed mode.
- [x] Tests prove that file-first mode either remains file-backed or shows a clear mismatch warning.

## Test Cases

- Start with `workflow_source: :database`, a file workflow, and no DB workflow; verify the file is seeded into DB and runtime uses DB.
- Save a DB workflow through `/workflows`; verify `WorkflowStore.current/0` and `/diagnostics/linear` now use the DB workflow.
- Activate an older DB workflow version; verify Linear diagnostics updates without process restart.
- Start with explicit file-first mode and an active DB workflow; verify `/workflows` shows that DB active workflow is not the runtime source.
- Start with `--port`, existing `WORKFLOW.md`, and active DB workflow; verify the documented precedence and UI source labels.
- Save invalid workflow; verify runtime source does not change.
- Verify auth protection remains unchanged for `/workflows` and `/diagnostics/linear`.

## Implementation Notes

- Prefer adding a small source-introspection API near `WorkflowStore`, for example:
  - `WorkflowStore.current_with_source/0`
  - or `Workflow.runtime_source/0`
- The returned source should include enough detail for UI:
  - `:file` with path/stamp
  - `:database` with workflow version id/version/source
  - `:setup_required`
- Avoid duplicating source-selection logic in LiveViews.
- `/workflows` should stop independently deciding that DB active means "current"; it should render both:
  - runtime current workflow
  - database version history
- After `Persistence.import_workflow/3` or `Persistence.activate_workflow_version/1`, trigger a store refresh and update the LiveView assigns from the canonical source API.
- `CLI.run_default/2` should set `:workflow_source` to `:database` whenever `--port` is present.
- Explicit workflow path runs should set `:workflow_source` to `:file`.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix lint`
- `mise exec -- mix test test/symphony_elixir/workflow_store_database_source_test.exs`
- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test`
- Manual check: change Linear `project_slug` in `/workflows`, open `/diagnostics/linear`, confirm the displayed slug and probe variables use the edited workflow.

## Completion Deviations

- Removed `database_or_file` from active runtime semantics. Historical completed plans still mention it as an earlier transition model.
- Implemented two explicit runtime modes: `:file` for explicit file/default non-port runs, and `:database` for `--port` dashboard-managed runs.
- In database mode, `WORKFLOW.md` is treated as an initialization seed only when no active DB workflow exists.
- Added `WorkflowStore.current_with_source/0` and surfaced runtime source on `/workflows` and `/diagnostics/linear`.
- Manual browser verification was not run in this environment; behavior is covered by LiveView and workflow store tests.

## Dependencies

- Database-backed port startup behavior from Task 017, superseding the earlier database-or-file transition model.
- First workflow UI from Task 018.
- Startup precedence plan from Task 019.
- Shared navigator from Task 021.
- Linear diagnostics page from Task 022.

## Handoff Notes

- Record the final startup precedence when both `WORKFLOW.md` and active DB workflow exist.
- Record whether Web-managed port mode becomes DB-preferred by default.
- Record how users intentionally keep file-first mode.
- Record which UI labels are used for runtime source and DB active source.

Final startup precedence:

- `./bin/symphony path/to/WORKFLOW.md` uses file mode.
- `./bin/symphony` without `--port` uses default `./WORKFLOW.md` file mode.
- `./bin/symphony --port <port>` uses database mode. If there is no active DB workflow, `WORKFLOW.md` is imported once as an initialization seed. If neither DB nor file is available, runtime enters `setup_required`.

Web-managed port mode is DB-backed by default. Users keep file-first behavior by passing an explicit workflow path or by running without `--port`.
