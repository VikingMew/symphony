# 246 Remove the DB-only source selector and reverse entries

## Goal

Delete the single-valued `workflow_source` selector, its CLI setter, and the package-side
reverse dependency on the runtime store; keep import/export codecs.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md M6. The architecture is now SQLite-active-workflow-only, but vestiges
remain: CLI deps map includes `set_workflow_source` accepting only `:database`
(cli.ex:25-31, 61-64, 73-80, 191-198) written into Application env every start;
`WorkflowStore` accepts `nil | :database | "database"` with other values silently becoming
setup-required (workflow_store.ex:198-200, 260-262); `Workflow.current/0` reverse-depends on the
runtime store (workflow.ex:47-70). Violates Linus "remove complexity" (config with one legal
value) and Carmack (illegal selector -> setup-required is a dual meaning).

## Scope

- Delete the CLI setter + deps field and `database_workflow_enabled?/0`; `WorkflowStore` reads the
  DB unconditionally.
- Runtime callers depend on `WorkflowStore` directly; `Workflow` keeps package parse/render
  duties (its import/export codecs — `load/1`, `parse_split_package/2`, `parse_content/1` — are
  NOT deleted; they serve Settings import/export and tests).
- Remove the `current/0` reverse entry from the package parser.

## Out of Scope

- Migrating tests that use the file loader as a fixture builder (separate low-value churn; not
  part of this runtime cleanup).
- The H1 typed-contract work (plan 239) — though this plan's deletion simplifies its surface.

## Acceptance Criteria

- `grep set_workflow_source|database_workflow_enabled?` in lib/ -> zero hits.
- App boots and reads the active workflow from DB exactly as before (behavioral equivalence).

## Test Cases

- Boot + config-load smoke tests (existing core/orchestrator startup suites).
- CLI test updates for the removed field.

## Implementation Notes

Production behavior has a single value — deleting branches is directly provable equivalent;
keep the change mechanical.

## Dependencies

- None.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

