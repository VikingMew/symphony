# Persistence and Authentication

Symphony uses local SQLite-backed persistence for runtime/configuration state and supports optional
username/password authentication for the Phoenix control plane.

## SQLite

The application uses `Ecto` with `ecto_sqlite3`.

Default database path:

```text
elixir/symphony.db
```

Override the path:

```bash
export SYMPHONY_DATABASE_PATH=/path/to/symphony.db
```

Run migrations:

```bash
cd elixir
mise exec -- mix ecto.migrate
```

Reset local development data by stopping the service and removing the SQLite database file, then running migrations again.

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

## Workflow Versions

Workflow versions persist the complete workflow package contract:

- parsed YAML config
- prompt body
- source
- active flag

Database-backed workflow loading supports explicit database mode:

```elixir
Application.put_env(:symphony_elixir, :workflow_source, :database)
```

The CLI starts in database workflow mode. If no active SQLite workflow exists, Symphony starts in
setup-required mode and does not poll Linear or schedule agents until `/settings/workflow` creates
the first active workflow. Local split package files (`workflow.yml` and `profiles.yml`) are import
and export artifacts, not startup seed data. Use `--database-path <path>` or
`SYMPHONY_DATABASE_PATH` to select a different SQLite database file.

## Web UI

The following browser pages are available when the Phoenix server is enabled:

- `/`
- `/runs`
- `/workers`
- `/settings`
- `/settings/projects`
- `/settings/workflow`
- `/settings/agents`
- `/settings/runtime`
- `/diagnostics/linear`

Settings is one tabbed page: Projects owns project-specific Linear project slug, repository URL,
and default branch; Workflow owns shared workflow/runtime/bootstrap policy; Agents owns execution
profiles and the shared base prompt; and Runtime shows tracker/config summary. Workflow and Agents
each show their own version history in the UI: Workflow history lists workflow settings saves,
while Agents history lists profile/prompt saves. Restoring a history row is section-scoped
and writes a new complete active workflow version instead of directly activating an older complete
package. Runtime reads the SQLite active workflow version; split
`workflow.yml`/`profiles.yml` packages are import/export artifacts. See
[Workflow 页面设计目标](workflow_page_design.zh-CN.md).

## Worker State

SQLite also stores Panel-side worker state:

- workers and worker sessions
- queued/running/completed/failed/cancelled tasks
- active, expired, released, and cancelled task leases
- worker task events

`SYMPHONY_EXECUTION_MODE=worker` makes the orchestrator enqueue worker tasks. The default
`centralized` mode continues to run Codex from the Panel process and can still use SSH hosts from
`worker.ssh_hosts` for remote centralized execution.
