# Test Database Isolation

## Policy

Tests must never read or write the local development SQLite database:

- `symphony.db`
- `symphony.db-shm`
- `symphony.db-wal`

Feature tests must use mocks, fakes, or dependency injection for persistence behavior. The default `mix test` suite must not start `SymphonyElixir.Repo`, run migrations, or create SQLite files.

## SQLite Usage

SQLite is not allowed in the default test suite.

If a future adapter-compatibility job is added, it must be explicit and non-default. It must not run through plain `mix test`, and it must not use the local development database.

`test/test_helper.exs` enforces this before the application starts:

- the configured test Repo database must not equal the development database path;
- the configured test Repo database must not be named `symphony.db`;
- the configured test Repo database must live under the system temporary directory.

The application supervisor also skips `SymphonyElixir.Repo` in `MIX_ENV=test`.

## Runtime Guard

Runtime code must not trust test-sourced workflow data. `Persistence.active_workflow_version/1` ignores workflow versions with `source = "test"` unless `:allow_test_workflow_source` is explicitly enabled by the test helper.

This prevents a previous test run from resetting the Web UI to test values such as:

- `api_key: "token"`
- `project_slug: "db-project"`

## Adding New Tests

Use a fake or mock when the test only needs to observe behavior around persistence.

Do not add direct `Repo` setup to default tests. If a test needs persistence behavior, add or extend a fake persistence module.

## Verification

Before and after running the test suite:

```bash
ls symphony.db symphony.db-shm symphony.db-wal
```

All three files should be absent in the project directory after `mix test`.
