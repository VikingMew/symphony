---
title: Test Database Isolation
genre: spec
domain: [testing, database]
status: current
language: en
updated: 2026-08-07
owner: SymphonyElixir.Repo
---

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

- `:start_repo` is set to `false`;
- `:persistence_module` is set to `SymphonyElixir.TestSupport.FakePersistence`;
- no default test helper reads the configured Repo database path, starts Repo, or runs migrations.

The application supervisor also skips `SymphonyElixir.Repo` in `MIX_ENV=test`. The default suite has a boundary test that asserts Repo is not running and no Symphony-named SQLite/DB files were created under the system temporary directory. Browser or OS cache `.db` files under the same temp root are ignored because they are not Symphony test artifacts.

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
find "$(elixir -e 'IO.write(System.tmp_dir!())')" -iname '*symphony*.db' -o -iname '*symphony*.sqlite'
```

No Symphony test database files should appear after `mix test`. The production/development database is only used by explicit app startup or migration commands, not by the default test suite.
