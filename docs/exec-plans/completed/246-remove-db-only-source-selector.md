# 246 Remove the DB-only source selector and reverse entries

## Goal

Delete the single-valued `workflow_source` selector, its CLI setter, and the package-side
reverse dependency on the runtime store; keep import/export codecs.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 710 tests, 2 failures (full suite). Both are the PRE-EXISTING known
  flaky families (CoreTest "run-start persistence failure" cross-file race + HookRunnerTest
  timeout diagnostics); isolated re-run of core + hook_runner + workflow_store = 48 tests,
  0 failures. Not introduced by this plan.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (cli.ex, workflow.ex, workflow_store.ex, the 4
  Workflow.current call sites, 7 test files; net -64/+13)
- grep acceptance: `set_workflow_source` / `database_workflow_enabled` / `Workflow.current(`
  in lib/ -> zero hits

## Completion Deviations

- CLI deps map entry `set_workflow_source` and its implementation deleted; `WorkflowStore`
  reads the DB unconditionally (no `database_workflow_enabled?/0`, no source branching).
- `Workflow.current/0` (package parser -> runtime store reverse dependency) DELETED; the four
  runtime call sites (config.ex, http_server.ex, prompt_builder.ex, status_dashboard.ex) now
  call `WorkflowStore` directly.
- Import/export codecs KEPT: `Workflow.load/1`, `parse_split_package/2`, `parse_content/1`,
  and the file-path helpers used by test fixtures remain (only the 5-line current/0 was removed).
- Tests no longer set `:workflow_source` env (setup/on_exit cleaned in 7 files).
- NOTE: first Codex run correctly BLOCKED on a whitelist gap (Workflow.current callers not
  listed); whitelist was extended with the 4 call-site files and the run completed cleanly —
  the guard worked as designed. Test baseline unchanged at 710.

