# Task 025: Test Database Isolation and Persistence Mocking

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 002, Task 003, Task 017, Task 023, Task 024
**Created**: 2026-05-05

## Goal

Prevent tests from reading or mutating the local development SQLite database (`symphony.db`) and move tests toward explicit mocks/fakes for persistence boundaries.

Running `mix test` must never change the operator's local runtime configuration, active workflow version, Linear token source, project slug, runs, tasks, workers, or other persisted dashboard state.

## Background

The local development database was polluted by test workflow versions:

- An active `workflow_versions` row had `source = "test"`.
- That row contained `api_key: "token"` and `project_slug: "db-project"`.
- The Web UI then showed `Token source: workflow literal`, `Token length: 5`, and `Project slug: db-project`, even though the operator had configured a real `LINEAR_API_KEY` and project slug.

This exposed two problems:

- Tests must not be able to operate on `elixir/symphony.db`.
- Runtime code should not trust test-sourced workflow versions outside the test environment.

Task 024 added token/source diagnostics, which made the failure visible. Task 025 makes this class of failure structurally hard to repeat.

## Scope

- Delete the polluted local SQLite files before continuing local validation.
- Add a hard guard so `MIX_ENV=test` cannot use the default development database path.
- Make test database usage explicit and isolated when an actual SQLite integration test is required.
- Prefer mocks/fakes at persistence boundaries for tests that do not need SQLite behavior.
- Keep integration tests that validate migrations, Ecto schemas, transactions, and SQLite-specific behavior on temporary per-run databases only.
- Add regression tests that fail if test configuration points at `symphony.db`.
- Add regression tests that non-test runtime ignores `source = "test"` workflow versions.
- Document the intended test strategy: mock by default, temporary SQLite only for persistence integration tests.

## Out of Scope

- Removing SQLite from the application runtime.
- Replacing Ecto.Repo in production code.
- Building a full in-memory persistence adapter for all runtime paths in one step.
- Rewriting every existing persistence-heavy test immediately if it genuinely validates SQLite behavior.
- Adding a database migration rollback or data recovery tool.

## Acceptance Criteria

- [x] `elixir/symphony.db`, `elixir/symphony.db-shm`, and `elixir/symphony.db-wal` are absent after cleanup.
- [x] `mix test` fails early if `SymphonyElixir.Repo` is configured to `elixir/symphony.db`.
- [x] `mix test` uses a temporary per-run database only when SQLite integration is required.
- [x] Tests that only need persistence behavior use mocks/fakes instead of touching SQLite.
- [x] Non-test runtime ignores active workflow versions with `source = "test"`.
- [x] Runtime Web UI cannot be reset to `api_key: "token"` / `project_slug: "db-project"` by a previous test run.
- [x] Documentation explains when to mock persistence and when a temporary SQLite integration test is allowed.
- [x] Verification commands prove the local DB is absent before and after test execution.

## Test Cases

- Assert the test helper configures `SymphonyElixir.Repo` to a path under `System.tmp_dir!()`.
- Assert the test helper rejects any Repo database path ending in `/symphony.db` or equal to the configured development database path.
- Assert non-test runtime does not return `source = "test"` from `Persistence.active_workflow_version/1`.
- Run a persistence integration test and verify it creates only a temporary SQLite file.
- Run `mix test` and verify `elixir/symphony.db` is not created.
- For a representative non-persistence feature test, replace direct Repo setup with a fake/mocked persistence boundary.

## Implementation Notes

- Add a small test guard in `test/test_helper.exs` before the application starts:
  - compute the development DB path from `config/config.exs` semantics;
  - compute the test Repo database path;
  - raise if they match or if the test path is inside the repo as `symphony.db`.
- Keep the current temporary SQLite test DB only for integration tests that exercise Ecto/migrations/transactions.
- Introduce narrow fake modules or dependency injection for tests that only need:
  - active workflow lookup,
  - workflow import/activation behavior,
  - run/task listing,
  - Linear diagnostics metadata.
- Maintain `:allow_test_workflow_source` as test-only and default it to false in runtime.
- The existing runtime guard should continue filtering `source = "test"` unless explicitly allowed by test configuration.

## Verification

- `ls elixir/symphony.db elixir/symphony.db-shm elixir/symphony.db-wal` should report all three files missing.
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix lint`
- `mise exec -- mix test`
- `mise exec -- mix build`
- Re-run `ls elixir/symphony.db elixir/symphony.db-shm elixir/symphony.db-wal` and confirm tests did not recreate local DB files.

## Completion Deviations

- Existing persistence integration tests still use SQLite, but only through a temporary per-run database under `System.tmp_dir!()`. This is intentional because those tests validate Ecto schemas, migrations, transactions, workflow version activation, task leases, and runtime persistence.
- The implementation adds an executable test database guard rather than converting every existing persistence integration test to a mock. Non-persistence tests should continue moving toward fakes/mocks when persistence behavior is not the subject under test.
- `config/config.exs` now defaults `MIX_ENV=test` Repo configuration to a temporary DB even before `test/test_helper.exs` runs, preventing early application startup from creating `symphony.db`.

## Dependencies

- SQLite persistence foundation from Task 002.
- Database workflow loading from Task 003.
- Port-mode database workflow bootstrap from Task 017.
- Runtime source consistency from Task 023.
- Linear diagnostics visibility from Task 024.

## Handoff Notes

- The polluted local DB files were deleted before this plan was created.
- The immediate observed bad active workflow was `source = "test"`, `api_key: "token"`, `project_slug: "db-project"`.
- The operator's expected `LINEAR_API_KEY` fingerprint was `746495404314`; the polluted workflow token fingerprint was `3c469e9d6c58`.
- Runtime must prefer real `web`/`file` workflow versions over any test-sourced artifacts.
- Test database protection lives in `test/support/database_isolation.exs` and is invoked before the application starts in `test/test_helper.exs`.
- Test strategy documentation lives in `docs/test_database_isolation.md`.
