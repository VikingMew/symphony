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

Database-backed workflow loading is explicit during the migration period:

```elixir
Application.put_env(:symphony_elixir, :workflow_source, :database)
```

Without that setting, the runtime keeps using file-backed `WORKFLOW.md` semantics.

## Web UI

The following authenticated pages are available when the Phoenix server is enabled:

- `/projects`
- `/runs`
- `/workflows`
- `/settings`

The workflow page supports raw `WORKFLOW.md` editing and version history. Structured field-by-field editing is intentionally left for the next UI refinement pass.

