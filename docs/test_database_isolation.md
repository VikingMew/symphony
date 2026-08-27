---
title: Test Database Isolation
genre: spec
domain: [testing, database]
status: current
language: en
updated: 2026-08-27
owner: SymphonyElixir.Repo
---

# Test Database Isolation

## Policy

The default test suite is database-free. Plain `mix test` and `make all` must not require a live
PostgreSQL service, start `SymphonyElixir.Repo`, apply migrations, invoke the SQLite importer, or
create database files.

Feature tests use fakes or dependency injection for persistence behavior. In
`test/test_helper.exs`:

- `:start_repo` is `false`;
- `:persistence_module` is `SymphonyElixir.TestSupport.FakePersistence`;
- no default helper reads `DATABASE_URL`, starts Repo, or runs migrations.

The application supervisor also skips Repo in `MIX_ENV=test`. A boundary test asserts that Repo is
not running and that the fake persistence provider is active.

## Explicit PostgreSQL Integration Target

Real adapter behavior belongs to the opt-in smoke target, outside ExUnit's default boundary:

```bash
export DATABASE_URL='postgresql://symphony:password@127.0.0.1:5432/symphony_smoke'
make pg-smoke
```

The target database must be isolated and empty. The smoke command applies the full migration
history, reverses and reapplies it, checks PostgreSQL column/constraint/index types, creates a
legacy SQLite fixture, imports all application tables, verifies relationships and active workflow
state, exercises representative persistence operations, performs 200 concurrent event writes,
and proves another write/read succeeds afterward. It also proves the importer rejects a non-empty
target.

SQLite in this target is an import fixture only. No Ecto SQLite adapter or selectable SQLite
runtime exists.

## Adding New Tests

Use a fake or mock when a test only needs to observe behavior around persistence. Do not add direct
Repo setup to default tests. Put database-specific semantics in the explicit PostgreSQL smoke
target or another clearly non-default integration command using a disposable database.

Runtime code must not trust test-sourced workflow data. Persistence ignores workflow versions with
`source = "test"` unless `:allow_test_workflow_source` is explicitly enabled by the test helper.
