# Task 002: SQLite Configuration Foundation

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: None
**Created**: 2026-05-01

## Goal

Introduce SQLite persistence as the foundation for configuration, workflow versions, runtime state, and future dashboard history.

## Background

Symphony currently relies on `WORKFLOW.md`, in-memory runtime state, and log files. That is useful for an experimental reference implementation, but the long-term product direction requires Web UI configuration, durable run history, and inspectable workflow versions.

SQLite is the right first persistent store because Symphony is expected to run as a single-node Web service first. It keeps setup simple while allowing Ecto migrations, schema validation, and future migration to Postgres if needed.

## Scope

- Add Ecto and SQLite support.
- Add an application Repo.
- Add migration infrastructure.
- Configure database path through runtime configuration.
- Add initial schemas needed by later tasks:
  - `projects`
  - `workflow_versions`
  - `tracker_configs`
  - `app_settings` or equivalent key/value settings table
  - `users` if Task 001 stores auth in SQLite
- Add tests for Repo startup and basic persistence.
- Document local database setup and reset commands.

## Out of Scope

- Moving workflow loading to the database. That belongs to Task 003.
- Persisting runtime run state. That belongs to Task 004.
- Full configuration UI. That belongs to Task 005.
- Multi-project Linear dispatch behavior. That belongs to Task 006.

## Acceptance Criteria

- [ ] `mix setup` installs SQLite/Ecto dependencies.
- [ ] The application can start with a configured SQLite database path.
- [ ] Migrations create the initial tables.
- [ ] Tests can run against an isolated test database.
- [ ] Existing non-database behavior still works.
- [ ] The database layer has a clear module boundary.
- [ ] Documentation explains where the SQLite file is stored and how to reset it locally.

## Test Cases

- Repo starts successfully with a temporary SQLite database.
- Migrations create all initial tables.
- Migration task is idempotent on an already-migrated database.
- Test environment uses an isolated database path.
- Project records can be inserted, validated, read, updated, and listed.
- Workflow version records can store raw workflow text, parsed YAML config, and prompt body.
- Tracker config records validate required fields and reject invalid tracker kinds.
- Settings records can be inserted and updated without duplicate-key surprises.
- Existing non-DB tests still run without requiring manual database setup.

## Implementation Notes

- Prefer `ecto_sqlite3` with `Ecto.Repo`.
- Keep DB access behind a small persistence/context layer instead of scattering Repo calls through orchestrator code.
- Use Ecto changesets for validation so Web UI forms can reuse the same rules later.
- Keep `WORKFLOW.md` as the active runtime source until Task 003 changes that behavior.
- Avoid storing secret plaintext in SQLite. Store secret metadata or password hashes only.

## Verification

- `mise exec -- mix deps.get`
- `mise exec -- mix ecto.create`
- `mise exec -- mix ecto.migrate`
- `mise exec -- mix test`
- Add focused persistence tests for initial schemas.

## Completion Deviations

- Implemented SQLite through `Ecto.Repo` and `ecto_sqlite3`.
- The initial schema includes projects, tracker configs, workflow versions, users, issues, runs, agent turns, workspaces, events, and settings.
- Test setup runs migrations against an isolated temporary SQLite database.

## Handoff Notes

- Record the selected SQLite adapter and database path convention.
- Record any migration/test setup commands added to `mix.exs` or `Makefile`.
- Record whether auth storage was included or deferred to Task 001.
