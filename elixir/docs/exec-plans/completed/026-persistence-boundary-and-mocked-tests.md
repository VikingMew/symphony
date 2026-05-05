# Task 026: Persistence Boundary and Mocked Tests

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 025
**Created**: 2026-05-05
**Completed**: 2026-05-05

## Goal

Make mocks/fakes the default and required approach for the test suite.

Ordinary tests must not start `SymphonyElixir.Repo`, run migrations, create SQLite files, or rely on temporary SQLite. Application code should resolve persistence through a configurable boundary so tests can replace persistence with fakes.

The only acceptable database usage after this task is outside the default test suite, behind an explicit manual/CI job for adapter compatibility if we later decide to keep one. It must not be part of `mix test`.

## Background

Task 025 prevented tests from touching `symphony.db` and added a temporary SQLite guard. That fixed the immediate data-loss/configuration pollution risk, but it still leaves too many tests coupled to a real database.

The mainstream testing shape should be:

- unit, Web UI, workflow-source, worker API, and orchestration tests: fake/mock persistence;
- no SQLite in the default `mix test` suite;
- runtime: real SQLite persistence.

## Scope

- Introduce a small persistence boundary that resolves the runtime persistence module from configuration.
- Default the boundary to `SymphonyElixir.Persistence`.
- Allow tests to set `:persistence_module` to a fake module.
- Move Web UI persistence calls through the boundary.
- Move `WorkflowStore` database workflow loading/seeding through the boundary.
- Move auth, worker API, and orchestration persistence calls through the boundary where required by tests.
- Replace existing DB-backed tests with fake persistence tests.
- Stop default `mix test` from starting `SymphonyElixir.Repo` or running Ecto migrations.
- Remove the remaining DB-backed tests from the suite or convert them to fake persistence coverage.
- Update test database isolation documentation to clarify that SQLite is not part of default tests.

## Out of Scope

- Replacing Ecto schemas.
- Removing SQLite from runtime.
- Building a separate CI matrix for adapter compatibility.

## Acceptance Criteria

- [x] A persistence boundary exists and returns `SymphonyElixir.Persistence` by default.
- [x] Tests can configure a fake persistence module without touching `Repo`.
- [x] Default `mix test` does not start `SymphonyElixir.Repo`.
- [x] Default `mix test` does not run Ecto migrations.
- [x] `AdminLive` uses the persistence boundary for project/run/workflow/worker/task reads and mutations.
- [x] `DashboardLive` uses the persistence boundary for workflow setup checks.
- [x] `WorkflowStore` uses the persistence boundary for database workflow loading and seeding.
- [x] Auth, worker API, and orchestration paths that need persistence in tests use the boundary or fakes.
- [x] Existing tests that used DB setup are converted to fake persistence coverage or removed.
- [x] Default `mix test` creates no SQLite database files anywhere in the project and does not require temporary SQLite.
- [x] `symphony.db` is absent before and after the full test suite.

## Test Cases

- Assert the boundary defaults to real persistence.
- Assert setting `:persistence_module` returns the fake module.
- Render `/projects` or `/workflows` with a fake persistence module and assert fake data appears.
- Save a workflow through `/workflows` with a fake persistence module and assert the fake receives the import call.
- Exercise worker API registration/claim/heartbeat with fake persistence.
- Exercise auth lookup with fake persistence.
- Exercise workflow database-source behavior with fake persistence, without `Repo`.
- Assert `Process.whereis(SymphonyElixir.Repo)` is nil in default tests.
- Run the full suite and confirm `symphony.db*` is not created.
- Run the full suite and confirm no project-local SQLite files are created.

## Implementation Notes

- Keep the boundary small:
  - `SymphonyElixir.PersistenceProvider.module/0`
  - optionally `put_module/1` only if needed by tests.
- Add a formal behaviour if it helps keep fake modules honest. The boundary must be explicit enough that future tests do not fall back to `Repo`.
- Use local `persistence()` helpers in modules being migrated so the production code remains easy to read.
- Fake persistence modules can return structs or maps as long as call sites only require field access.
- Application supervision should not start `SymphonyElixir.Repo` in `MIX_ENV=test`.
- `test/test_helper.exs` should not run migrations for the default suite.

## Verification

- [x] `find . -maxdepth 2 -name 'symphony.db*' -o -name '*.db'`
- [x] `mise exec -- mix format --check-formatted`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix build`
- [x] `find . -maxdepth 2 -name 'symphony.db*' -o -name '*.db'`

## Completion Deviations

The delivered test shape removes the `:db_integration` path from the suite. Remaining coverage uses fake persistence for Web UI, workflow source, auth, Linear diagnostics, and worker API behavior. No default test starts Repo, runs migrations, or creates project-local SQLite files.

## Dependencies

- Task 025 test database isolation and runtime protection.

## Handoff Notes

- This task replaces "safe temporary DB tests" with "mock/fake by default and no default DB".
- Existing DB-backed tests are not allowed to remain in the suite. Add fake persistence coverage for behavior tests instead.
