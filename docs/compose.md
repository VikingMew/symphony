---
title: Compose and PostgreSQL Operations
genre: guide
domain: [deployment, operations, persistence]
status: current
language: en
updated: 2026-08-27
owner: compose.yaml
---

# Compose and PostgreSQL Operations

This is the source of truth for the supported self-hosted Symphony stack and for the one-way
legacy SQLite cutover. The stack runs PostgreSQL, a one-shot migration release, and the Symphony
OTP release. An opt-in `execution-worker` profile deploys the trusted worker-v1 HTTP runtime; it is
distinct from the SSH `worker` Docker target. PostgreSQL is reachable only on the internal Compose
network. The Panel and execution worker have separate egress networks and share only an internal
control network.

## Environment and Credentials

Copy the template and replace every `change-me` value:

```bash
cp .env.example .env
chmod 600 .env
```

`.env` is ignored by git. Never bake tokens into the image or render the substituted Compose
configuration into a persistent file.
`POSTGRES_*` configures the PostgreSQL container. Symphony itself receives one `DATABASE_URL`;
there is no second application database model. If the password contains URL-significant
characters, percent-encode it in `DATABASE_URL`.

The environment reference covers PostgreSQL, Linear, OpenAI/Codex, GitHub, dashboard auth,
worker registration, SSH, reverse-proxy settings, release `SECRET_KEY_BASE`, and upper/lower-case
proxy variables. Prefer a password hash over a plaintext dashboard password. Use either `GH_TOKEN`
or `GITHUB_TOKEN`, not both, unless their precedence is intentional.

Codex, GitHub CLI, and SSH state use named volumes:

```bash
docker compose run --rm symphony codex login
docker compose run --rm symphony gh auth login
docker compose run --rm symphony ssh-keygen -t ed25519
```

Token environment variables are an alternative to interactive `gh` authentication. The service
process must see working `gh` credentials because SYM-1 PR lookup/creation happens at the Symphony
boundary. Child Codex processes inherit the documented OpenAI, GitHub, Linear, and proxy
environment after Symphony's existing sensitive-environment policy is applied.

## Build and First Start

Validate the model before changing containers:

```bash
docker compose --env-file .env config --quiet
```

The quiet form validates interpolation and structure without printing substituted secrets. The
checked-in `compose.yaml` and `.env.example` contain placeholders, not credentials. The worker
profile and its failure drills are operated through
[Trusted HTTP Execution Worker Operations](execution-worker-operations.md).

Build and verify the release image:

```bash
docker compose build
docker compose run --rm --no-deps symphony sh -lc '
  id && test "$(id -u)" != 0 &&
  codex --version && gh --version && git --version && ssh -V && rg --version &&
  test -z "$(command -v mix)" && test -z "$(command -v gcc)" &&
  test ! -e /app/mix.exs && test ! -d /app/config && test ! -d /app/test
'
```

Start the stack:

```bash
docker compose up -d
docker compose ps
docker compose logs migrate
curl --fail http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT:-4000}/health/live
curl --fail http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT:-4000}/health/ready
```

Compose waits for `pg_isready`, requires the migration container to exit successfully, then starts
Symphony. `/health/live` proves HTTP is serving; `/health/ready` also proves persistence is
reachable. An empty but migrated database reports setup-required while keeping Settings available.

Run migrations explicitly when diagnosing or before a controlled start:

```bash
docker compose up -d postgres
docker compose run --rm migrate
```

## Daily Operations

```bash
docker compose ps
docker compose logs --tail=200 -f symphony
docker compose logs --tail=200 postgres
docker compose stop
docker compose start
```

`docker compose down` removes containers and networks but preserves named volumes. Never use
`docker compose down -v` unless intentionally deleting PostgreSQL data, workspaces, logs, and
credential state.

The container paths are stable:

| Data | Container path | Volume |
| --- | --- | --- |
| PostgreSQL cluster | `/var/lib/postgresql/data` | `postgres_data` |
| Logs | `/data/logs` | `symphony_logs` |
| Workspaces | `/data/workspaces` | `symphony_workspaces` |
| Codex state | `/home/symphony/.codex` | `codex_home` |
| GitHub CLI state | `/home/symphony/.config/gh` | `gh_config` |
| SSH state | `/home/symphony/.ssh` | `ssh_home` |

Workflows imported from a host may contain host-only workspace paths. Before enabling
listening, change the active workflow workspace root to `/data/workspaces` and verify repository,
hook, SSH, and worktree paths are container-visible.

## Upgrade and Rollback

Before an upgrade, take a PostgreSQL backup and retain the prior image tag:

```bash
docker compose exec -T postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "symphony-$(date +%Y%m%d-%H%M%S).dump"
docker image tag symphony:local symphony:rollback
docker compose build --pull
docker compose up -d
```

The migration job runs before the new service. Verify both health endpoints and recent
project/run/event state. To roll application code back, restore the prior image tag in Compose (or
retag `symphony:rollback`), then start it only if its migration compatibility is understood. If a
database restore is required, stop Symphony first and use the procedure below.

## PostgreSQL Backup and Restore

Create and inspect a custom-format dump:

```bash
docker compose exec -T postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > symphony.dump
docker compose exec -T postgres pg_restore --list < symphony.dump | head
```

Restore into a new database so the current one remains available for rollback:

```bash
docker compose stop symphony
docker compose exec -T postgres sh -lc \
  'createdb -U "$POSTGRES_USER" symphony_restore'
docker compose exec -T postgres sh -lc \
  'pg_restore -U "$POSTGRES_USER" -d symphony_restore --exit-on-error' < symphony.dump
```

Update `DATABASE_URL` to the restored database, rerender `docker compose config`, run the migration
service, and start Symphony. Compare all application-table counts and inspect the active workflow,
recent runs, and recent events before enabling listening. Roll back by restoring the prior
`DATABASE_URL`; do not overwrite the original database during verification.

## Legacy SQLite Cutover

Cutover requires a maintenance window. The SQLite source is import-only and the PostgreSQL target
must already be migrated and contain zero application rows.

### 1. Preflight and write freeze

1. Record the current application artifact/version and SQLite path.
2. Verify enough disk space and confirm `sqlite3`, `pg_dump`, and `psql` are available.
3. Stop the SQLite-capable Symphony process and confirm no process has the database open.
4. Create a consistent backup while stopped:

```bash
sqlite3 /absolute/path/symphony.db ".backup '/absolute/path/symphony.cutover.db'"
sqlite3 -readonly /absolute/path/symphony.cutover.db "PRAGMA quick_check"
```

Retain the original database, the cutover backup, and the prior SQLite-capable application
artifact. Do not copy live `-wal` or `-shm` files; the importer refuses a source with those
sidecars.

### 2. Prepare an empty PostgreSQL target

Set `POSTGRES_*` and `DATABASE_URL` in `.env`, then:

```bash
docker compose up -d postgres
docker compose run --rm migrate
docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT COUNT(*) FROM projects"'
```

The application-table count must be zero. Migration rows in `schema_migrations` are expected.

### 3. Import and verify

Mount only the directory containing the stopped backup, read-only:

```bash
docker compose run --rm --no-deps \
  -v /absolute/path:/cutover:ro \
  -e SQLITE_BACKUP_PATH=/cutover/symphony.cutover.db \
  symphony /app/bin/symphony eval 'SymphonyElixir.Release.import_sqlite!()'
```

The command imports users, projects, tracker configs, the active legacy workflow for each project, issues, runs, agent
turns, workspaces, events, app settings, workers, sessions, tasks, and leases in dependency order.
It prints and verifies a row count for every table inside one PostgreSQL transaction. Any source
schema error, invalid JSON, foreign-key error, count mismatch, or non-empty target rolls back the
import.

Verify independently:

```bash
docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT project_id, source, updated_at FROM workflows ORDER BY project_id"'
docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT status, COUNT(*) FROM runs GROUP BY status ORDER BY status"'
docker compose exec -T postgres sh -lc \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > post-cutover.dump
```

Review Settings without enabling listening. Confirm current workflows, project repository
URLs/default branches, `/data/workspaces`, hooks, SSH hosts, credentials, recent run/event history,
and worker/task state.

### 4. Switch or roll back

Start the PostgreSQL release, verify `/health/live` and `/health/ready`, then enable listening.
Monitor logs and confirm a new persistence write is visible after restart.

Rollback is bounded but not zero-downtime: stop the PostgreSQL release before further writes,
retain its database/dump for diagnosis, restore the untouched pre-cutover SQLite database, and
start the retained SQLite-capable application artifact with its prior configuration. The new
release cannot use SQLite. Never attempt to merge writes made independently on both sides.

## Persistence and Restart Verification

Create or identify a harmless durable Settings change, then recreate only containers:

```bash
docker compose up -d --force-recreate
docker compose ps
curl --fail http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT:-4000}/health/ready
```

Confirm the Settings change, PostgreSQL table counts, logs, and workspace marker still exist.
Exercise restart policies separately:

```bash
docker compose exec -T symphony sh -lc 'kill -KILL 1'
docker compose ps
docker compose exec -T postgres sh -lc 'kill -KILL 1'
docker compose ps
```

Both long-running services use `unless-stopped`; wait for health to recover and confirm the same
database state remains. A normal Symphony restart must not produce SQLite lock errors because no
SQLite runtime writer exists.

## Local CLI Development

Compose is not required for ordinary code/test work. Point the local CLI at any reachable
PostgreSQL database:

```bash
export DATABASE_URL='postgresql://symphony:password@127.0.0.1:5432/symphony_dev'
export SYMPHONY_DATABASE_POOL_SIZE=5
mise exec -- mix setup
mise exec -- mix symphony.migrate
mise exec -- mix build
mise exec -- ./bin/symphony --port 4000 --logs-root ./log
```

Plain `mix test` and `make all` remain database-free. Use the isolated `make pg-smoke` target only
with a fresh empty PostgreSQL smoke database. No launchd deployment machinery is maintained.
