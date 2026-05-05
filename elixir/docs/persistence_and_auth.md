# Persistence and Authentication

Symphony now has a local SQLite-backed persistence foundation and optional username/password authentication for the Phoenix control plane.

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

When authentication is enabled:

- Browser routes redirect unauthenticated users to `/login`.
- JSON API routes return `401`.
- `/logout` clears the browser session.

## Workflow Versions

Workflow versions persist the complete `WORKFLOW.md` contract:

- raw Markdown
- parsed YAML front matter
- prompt body
- source
- active flag

Database-backed workflow loading supports explicit database mode:

```elixir
Application.put_env(:symphony_elixir, :workflow_source, :database)
```

The CLI enables database mode automatically when started with `--port` and no explicit workflow
path. In that mode, `WORKFLOW.md` is an initialization file only: if no active SQLite workflow
exists, Symphony imports it once. If neither SQLite nor `WORKFLOW.md` has a workflow, the dashboard
starts in setup-required mode and `/workflows` can create the first active workflow. Traditional
non-port CLI runs and explicit workflow paths keep file-backed `WORKFLOW.md` semantics.

## Web UI

The following authenticated pages are available when the Phoenix server is enabled:

- `/projects`
- `/runs`
- `/workers`
- `/workflows`
- `/settings`

The workflow page supports raw `WORKFLOW.md` editing and version history. Structured field-by-field editing is intentionally left for the next UI refinement pass.
