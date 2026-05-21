# Symphony

Symphony is a Phoenix/Elixir control plane that turns Linear issues into isolated Codex agent runs.

It watches configured work states, prepares a per-issue workspace, starts `codex app-server`, gives the agent a workflow/profile prompt, records the run, and exposes enough UI and logs for an operator to understand what happened.

> [!WARNING]
> This fork is alpha software for trusted environments. It intentionally diverges from the upstream OpenAI Symphony preview.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

## What It Does

- Polls Linear for issues in workflow-defined active states.
- Runs Codex locally, over configured SSH worker hosts, or through the worker task API.
- Creates deterministic per-issue Git worktrees/workspaces.
- Keeps runtime configuration in SQLite-backed Settings and workflow versions.
- Imports and exports workflow packages for portability, while the active database workflow remains runtime truth.
- Persists projects, workflow versions, issues, runs, events, agent turns, workers, tasks, leases, and workspace records.
- Provides Dashboard, Runs, Run Detail, Issues, Events, Workers, Linear diagnostics, Settings, and Analytics pages.
- Exposes structured logs, JSON observability APIs, worker APIs, and health probe endpoints.

## Core Concepts

| Concept | Meaning |
| --- | --- |
| Project | A configured Linear project slug plus repository URL, default branch, checkout depth, and enablement. |
| Workflow | Shared runtime policy: active states, terminal states, transitions, bootstrap behavior, hooks, polling, and worker/runtime settings. |
| Agent profile | A stage-specific prompt and update policy, such as refinement, implementation, or merge. |
| Run | One persisted attempt to work an issue. Runs have timestamps, status, attempt, failure reason, events, and agent turns. |
| Workspace | The per-issue filesystem location where Codex works. |
| Worker mode | A dashboard/queue mode where external workers claim tasks through `/api/worker/v1/*`. |

## Quick Start

Requirements:

- `mise`
- Linear personal API token in `LINEAR_API_KEY`
- Codex CLI available to the runtime user

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix ecto.migrate
mise exec -- mix build
mise exec -- ./bin/symphony --port 4000
```

Open [http://127.0.0.1:4000/](http://127.0.0.1:4000/), then configure:

1. Settings / Projects: Linear project slug and repository URL.
2. Settings / Workflow: active states, terminal states, transitions, bootstrap, hooks, polling, and runtime settings.
3. Settings / Agents: base prompt and profile prompts.
4. Settings / Import: optional package import for workflow/profile YAML.

If SQLite has no active workflow version, Symphony starts in setup-required mode and does not listen for Linear work until Settings creates the first workflow.

## Configuration Model

The runtime source of truth is the SQLite database. `workflow.yml` and `profiles.yml` are import/export artifacts, not files that Symphony watches at runtime.

Useful runtime options:

```bash
mise exec -- ./bin/symphony \
  --port 4000 \
  --database-path /path/to/symphony.db \
  --logs-root /path/to/logs
```

Common environment variables:

| Variable | Purpose |
| --- | --- |
| `LINEAR_API_KEY` | Linear API access. |
| `SYMPHONY_DATABASE_PATH` | Default SQLite location when `--database-path` is not passed. |
| `SYMPHONY_AUTH_ENABLED` | Enables username/password auth for the web UI/API. |
| `SYMPHONY_ADMIN_USERNAME` / `SYMPHONY_ADMIN_PASSWORD` | Simple local admin auth. Prefer a hash for shared environments. |
| `SYMPHONY_EXECUTION_MODE=worker` | Queue work for external workers instead of local Codex execution. |
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` | Used for Linear/Codex subprocess network access. |
| `SYMPHONY_TRUST_X_FORWARDED_HEADERS=true` | Trust reverse-proxy forwarded scheme/host/prefix headers. |
| `SYMPHONY_PUBLIC_URL` | Optional fixed public base URL behind a proxy. |

## Operating Modes

| Mode | Use When |
| --- | --- |
| Local centralized | You want one machine to run the dashboard, SQLite, workspaces, and Codex. |
| Centralized with SSH hosts | You want Symphony to coordinate work but run Codex on configured SSH hosts. |
| Worker mode | You want the dashboard/queue separated from external workers that claim tasks over HTTP. |
| Dashboard-first setup | You want to start with an empty database and create configuration through Settings. |

## Observability

| Surface | Path |
| --- | --- |
| Live runtime dashboard | `/` |
| Historical analytics | `/analytics` |
| Runs list/detail | `/runs`, `/runs/:id` |
| Issue detail | `/issues/:identifier` |
| Raw events | `/events` |
| Worker registry/tasks | `/workers` |
| Linear diagnostics | `/diagnostics/linear` |
| Settings | `/settings` |
| JSON state API | `/api/v1/state` |
| Health probes | `/health/live`, `/health/ready` |

Logs are normal structured application logs. There is no TUI status surface.

## Deployment

Symphony does not need to own public TLS or certificate issuance. Put it behind Nginx, Kubernetes Ingress, or another trusted proxy, and enable forwarded headers only at that boundary.

See [elixir/docs/deployment.md](elixir/docs/deployment.md) for Nginx, Kubernetes, WebSocket, health probe, and forwarded-header examples.

Docker targets are documented in [elixir/README.md](elixir/README.md).

## Development

```bash
cd elixir
mise exec -- mix test
mise exec -- mix test --cover
mise exec -- mix lint
mise exec -- mix exec_plans.check
```

Exec plans are the implementation ledger:

- Active work: [elixir/docs/exec-plans/active](elixir/docs/exec-plans/active)
- Completed work: [elixir/docs/exec-plans/completed](elixir/docs/exec-plans/completed)
- Index and rules: [elixir/docs/exec-plans/README.md](elixir/docs/exec-plans/README.md)

## Documentation

- [SPEC.md](SPEC.md): language-agnostic service specification.
- [ARCHITECTURE.md](ARCHITECTURE.md): implementation architecture.
- [CODE_STRUCTURE.md](CODE_STRUCTURE.md): code structure overview.
- [elixir/README.md](elixir/README.md): Elixir implementation guide.
- [elixir/docs/user_guide.zh-CN.md](elixir/docs/user_guide.zh-CN.md): Chinese operator guide.
- [elixir/docs/long_term_direction.zh-CN.md](elixir/docs/long_term_direction.zh-CN.md): long-term direction.
- [elixir/docs/documentation_alignment.md](elixir/docs/documentation_alignment.md): long-lived documentation alignment.
- [elixir/docs/persistence_and_auth.md](elixir/docs/persistence_and_auth.md): SQLite and auth details.
- [elixir/docs/deployment.md](elixir/docs/deployment.md): reverse proxy and Kubernetes deployment.

## Status

Implemented today:

- database-backed runtime configuration and workflow versions;
- Linear tracker integration and diagnostics;
- project/workflow/agent/runtime Settings;
- Codex app-server orchestration;
- centralized, SSH-host, and worker-backed execution paths;
- worktree/workspace source preparation;
- persisted runs, events, agent turns, worker tasks, and analytics;
- health endpoints and reverse proxy support.

Still alpha:

- APIs and UI are changing quickly;
- no multi-tenant hardening;
- SQLite is the supported persistence backend;
- operators should review prompts, skills, sandbox, approval, and repository safety before using it on important code.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
