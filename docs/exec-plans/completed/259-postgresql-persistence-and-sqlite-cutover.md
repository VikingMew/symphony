# 259 PostgreSQL persistence and SQLite cutover

## Goal

Eliminate production SQLite write-contention failures by making PostgreSQL the only supported
runtime persistence backend, while providing one explicit, data-preserving import path from a
stopped and backed-up legacy `symphony.db`.

## Status

Completed on 2026-08-27.

## Background

Concurrent SQLite writes can raise `Exqlite.Error: Database busy`. The Orchestrator currently
propagates that persistence failure, terminates, and later reconciliation marks live work failed.
The local file contract, SQLite adapter, lock retries, immediate transactions, and one historical
table-rebuild migration all encode the backend that creates this failure mode.

SYM-3 already moved normal `WorkflowStore` reads to one atomic in-memory snapshot. That
architecture remains intact: PostgreSQL is the durable authority, while public workflow reads stay
memory-only.

## Scope

- Replace `ecto_sqlite3`/`Ecto.Adapters.SQLite3` with `postgrex`/`Ecto.Adapters.Postgres`.
- Configure the application Repo through required `DATABASE_URL` plus an environment-driven pool
  size; remove the database-file CLI and environment contracts.
- Fail explicitly when database configuration is missing or PostgreSQL is unreachable, and run
  migrations before normal runtime supervision starts.
- Make the complete migration history valid on a fresh PostgreSQL database, including UUID keys,
  foreign keys, indexes, microsecond UTC timestamps, JSON/map columns, and operator-run fields.
- Remove Exqlite lock retries and SQLite-only transaction options or raw SQL.
- Add a supported cutover command from a frozen SQLite backup into an already migrated, empty
  PostgreSQL database. Import all application tables in dependency order, preserve values and
  relationships, reject non-empty targets, and report verification counts.
- Keep ordinary tests Repo-free and database-free. Cover persistence decisions with narrow fakes
  and put real migration/import/concurrency coverage behind an explicit PostgreSQL smoke command.
- Update current persistence, configuration, test-isolation, architecture, and operations
  documentation. Preserve split workflow/profile packages as import/export artifacts.

## Out of Scope

- A selectable SQLite runtime adapter or in-place upgrade of a SQLite file.
- Changing Orchestrator failure, reconciliation, or listening semantics.
- Multi-node scheduling, HA, read replicas, or PgBouncer.
- Zero-downtime cutover.

## Acceptance Criteria

1. Production code uses PostgreSQL only; there is no active SQLite runtime path, Exqlite lock
   handling, `--database-path`, `SYMPHONY_DATABASE_PATH`, or immediate SQLite transaction mode.
2. `DATABASE_URL` is required for runtime/migration commands, Repo pool sizing is environment
   driven, and missing or unreachable configuration produces an explicit database failure.
3. A fresh PostgreSQL database applies the complete migration history with the expected schema,
   constraints, indexes, UUID IDs, timestamp types, JSON defaults, and supported reversals.
4. The importer accepts only a stopped SQLite source backup and an already migrated empty target;
   it imports every application table in dependency order, preserves IDs, relationships,
   timestamps, maps, and the active workflow version, and prints matching per-table counts.
5. The cutover runbook covers preflight, write freeze, backup, target migration, import,
   verification, switch, and rollback using the untouched backup and prior SQLite-capable artifact.
6. `mix test` and `make all` run without PostgreSQL and do not start the Repo or create database
   files.
7. An explicit PostgreSQL smoke command covers migrations, importer behavior, representative
   persistence operations, concurrent event writes, and a usable write/read after concurrency,
   with no database-busy or lock failure.
8. Current documentation names PostgreSQL as durable runtime authority and preserves SYM-3's
   memory-only `WorkflowStore` read contract.

## Test Cases

- Config validation for missing/blank `DATABASE_URL`, valid URL, pool-size parsing, and explicit
  startup errors.
- CLI parsing without `--database-path` and with the retained logs/port/default-import options.
- Migration up/down checks and PostgreSQL catalog assertions for constraints, indexes, JSONB, UUID,
  and timestamp columns.
- Import refusal for a non-empty target, source schema/value decoding, per-table import and count
  verification, relationship preservation, and active workflow preservation.
- Project bootstrap concurrency through the PostgreSQL transaction/unique-constraint contract.
- Concurrent event inserts followed by another write and read.
- Default-suite boundary assertions that the Repo remains stopped and no database artifacts exist.

## Implementation Notes

- Keep `SymphonyElixir.Config` as the runtime configuration access boundary. Compose `POSTGRES_*`
  values configure the database service; the application still receives exactly one
  `DATABASE_URL`.
- Preserve migration versions but rewrite the SQLite-only operator-run migration in portable Ecto
  form because pre-release PostgreSQL databases always start fresh.
- Use SQLite only inside the cutover command. Its reader must not be available as a runtime Repo
  option.
- Keep importer transactions explicit and fail the whole import on any row/count mismatch.
- The smoke command is an opt-in Mix alias/task and is not part of the default ExUnit suite.

## Verification

- `mix symphony.postgres_smoke` passed against PostgreSQL 17 in Docker. The task applied the
  complete migration history, rolled every migration down and back up, asserted PostgreSQL UUID,
  JSONB, timestamp, foreign-key, and index metadata, and exercised concurrent default-project
  bootstrap.
- The same smoke imported one related row in each of the 14 application tables from a stopped
  SQLite fixture, verified IDs/relationships/the active workflow, rejected a second import into
  the non-empty target, completed 200 concurrent event writes, and performed a successful
  write/read afterward. It ended with `concurrent_event_writes=200 post_write=usable result=PASS`
  and no database-busy or lock failure.
- `mix test` ran while the Compose PostgreSQL and Symphony services were stopped: 759 tests,
  0 failures, 2 skipped. No Repo or database service was started by the default test suite.
- `make all` passed in an isolated Linux build with no PostgreSQL service: format check,
  exec-plan/spec checks, strict Credo, the 85% coverage gate, and Dialyzer with zero errors.
- `mix docs.check`, `mix specs.check`, `mix exec_plans.check`, and `git diff --check` passed after
  the documentation and plan lifecycle updates.

## Completion Deviations

None. SQLite remains available only through the external `sqlite3` reader used by the one-way
cutover command; no SQLite adapter or runtime selection path remains in the application.

## Dependencies

- SYM-1 merged in `origin/main` as `3d14d58`; its `gh`-based PR handoff must remain available.
- SYM-3 merged in `origin/main` as `ab717b9`; its memory snapshot architecture must remain intact.
- Plan 260 depends on this plan's verified PostgreSQL release contract.

## Handoff Notes

Complete and verify this plan before completing plan 260. The production runtime must never switch
back to the SQLite import dependency after cutover.
