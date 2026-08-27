---
title: Persistence and Authentication
genre: reference
domain: [persistence, auth]
status: current
language: en
updated: 2026-08-27
owner: SymphonyElixir.Persistence
---

# Persistence and Authentication

Symphony uses PostgreSQL for runtime/configuration state and supports optional username/password
authentication for the Phoenix control plane. SQLite is supported only as a frozen legacy import
source during cutover; it is not a runtime backend.

## PostgreSQL

The application uses Ecto with `postgrex`. Every application, migration, release, and cutover
command uses one required connection contract:

```bash
export DATABASE_URL='postgresql://symphony:password@127.0.0.1:5432/symphony'
export SYMPHONY_DATABASE_POOL_SIZE=5
```

`DATABASE_URL` must identify an existing database. Symphony does not create a PostgreSQL database
or silently substitute a local file. A missing URL, unreachable server, or failed migration stops
startup with an explicit database error.

Run migrations before starting the service:

```bash
mise exec -- mix symphony.migrate
```

The local `bin/symphony` development command also applies pending migrations before starting the
supervision tree. The Compose stack uses a one-shot release migration service and starts Symphony
only after that service succeeds.

## Durable Workflow Authority

PostgreSQL owns projects, workflow versions, issues, runs, events, agent turns, workspaces, workers,
sessions, tasks, leases, users, tracker configuration, and application settings. One active workflow
version exists per enabled project.

At cold start `WorkflowStore` loads the active workflows and atomically publishes a coherent
in-memory snapshot. Normal runtime config, prompt, dashboard, diagnostics, and dispatch reads use
only that snapshot; they do not query PostgreSQL. Explicit Settings mutations persist first and
republish before returning success. A failed background refresh retains the last-known-good
snapshot and reports the database error rather than presenting it as setup-required.

If the migrated database is genuinely empty, Symphony starts in setup-required mode and does not
poll Linear or schedule agents until Settings creates a project and active workflow. Checked-in
`workflow.yml` and `profiles.yml` remain import/export artifacts, not runtime fallbacks.

## Legacy SQLite Cutover

The supported one-way path imports a stopped, backed-up legacy `symphony.db` into an already
migrated, empty PostgreSQL database. It preserves IDs, foreign-key relationships, timestamps,
JSON/map values, and active workflow versions, verifies every table count, and refuses a non-empty
target or a source with live `-wal`/`-shm` sidecars.

The complete maintenance-window, verification, switch, and rollback procedure is owned by
[Compose and PostgreSQL Operations](compose.md#legacy-sqlite-cutover). The prior SQLite-capable
application artifact and untouched backup are required for rollback; the new application cannot
select SQLite at runtime.

## Authentication

Authentication is disabled by default for local compatibility.

Enable it:

```bash
export SYMPHONY_AUTH_ENABLED=true
export SYMPHONY_ADMIN_USERNAME=admin
export SYMPHONY_ADMIN_PASSWORD='choose-a-password'
```

For production-like use, prefer a password hash:

```bash
export SYMPHONY_AUTH_ENABLED=true
export SYMPHONY_ADMIN_USERNAME=admin
export SYMPHONY_ADMIN_PASSWORD_HASH='pbkdf2_sha256$...'
```

When browser/API authentication is enabled:

- Browser routes redirect unauthenticated users to `/login`.
- JSON API routes return `401`.
- `/logout` clears the browser session.

The worker API uses its own protocol authentication. Registration requires
`SYMPHONY_WORKER_REGISTRATION_TOKEN` through either `Authorization: Bearer <token>` or
`x-symphony-worker-token`. Subsequent worker calls identify the registered session with
`x-symphony-worker-id`, `x-symphony-worker-session`, and optionally
`x-symphony-worker-protocol`.

## Worker State

PostgreSQL also stores Panel-side worker state:

- workers and worker sessions;
- queued/running/completed/failed/cancelled tasks;
- active, expired, released, and cancelled task leases;
- worker task events.

`SYMPHONY_EXECUTION_MODE=worker` makes the orchestrator enqueue worker tasks. The default
`centralized` mode runs Codex from the Symphony process and can still use configured SSH hosts for
remote centralized execution.
