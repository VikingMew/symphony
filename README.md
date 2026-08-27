# Symphony

[![CI](https://github.com/VikingMew/symphony/actions/workflows/make-all.yml/badge.svg)](https://github.com/VikingMew/symphony/actions/workflows/make-all.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> [!IMPORTANT]
> This repository is a fork of the upstream OpenAI Symphony preview. It has diverged into an Elixir/Phoenix control plane with PostgreSQL-backed runtime settings, persisted run history, Linear diagnostics, and worker execution paths.

Symphony is a Phoenix/Elixir control plane for running Codex agents from Linear issues.

It watches configured Linear workflow states, prepares an isolated workspace for each issue, starts `codex app-server`, applies a workflow/profile prompt, records the run, and exposes operator pages for understanding what happened.

> [!WARNING]
> This fork is alpha software for trusted environments.

## What Symphony Provides

- Linear-backed issue discovery and workflow-state routing.
- Local centralized Codex execution by default.
- Optional remote execution through configured SSH worker hosts.
- Optional HTTP worker-task queue mode for external workers.
- Per-issue workspaces and Git worktrees.
- PostgreSQL-backed projects, workflow versions, runtime settings, runs, events, agent turns, workers, tasks, leases, and workspace records.
- Settings pages for Projects, Workflow, Agents, Runtime, and package import.
- Dashboard, Runs, Run Detail, Issues, Events, Workers, Linear diagnostics, and Analytics pages.
- Structured logs, JSON observability APIs, worker APIs, and health probes.

## How It Works

```text
Linear issue
  -> Symphony scheduler
  -> workflow/profile policy
  -> isolated workspace
  -> codex app-server
  -> persisted run history
  -> operator dashboard and diagnostics
```

The default workflow is intentionally gated by human review states:

```text
Backlog -> Refining -> Needs Refinement Review -> Ready -> In Progress
  -> Ready to Merge -> Done
```

`Refining`, `Ready`, and `In Progress` are agent-work states. `Needs Refinement Review` and
`Ready to Merge` are human-review states and are never dispatched. Implementation completion is
explicit: after Codex validates, commits, and pushes the exact Linear branch, Symphony finds or
opens the GitHub PR and only then moves the issue to `Ready to Merge`. A human merges on GitHub;
Linear's GitHub automation owns the final move to `Done`.

## Core Concepts

| Concept | Meaning |
| --- | --- |
| Project | A configured Linear project slug plus repository URL, default branch, checkout depth, workspace source policy, and optional hook overrides. |
| Workflow | Runtime policy: active states, terminal states, transitions, bootstrap behavior, hooks, polling, and execution settings. One active workflow version exists per enabled project. |
| Agent profile | A stage-specific prompt and update policy, such as refinement or implementation. |
| Run | One persisted attempt to work an issue, including status, attempt, timing, failure reason, events, and agent turns. Runs, issues, events, and worker tasks carry the originating `project_id`. |
| Workspace | The per-issue filesystem location where Codex works, isolated per repository so multiple projects stay separate. |
| Worker mode | Optional HTTP task-queue mode where external workers claim tasks through `/api/worker/v1/*`. |

Symphony maintains multiple projects concurrently: one Linear project + one repository each,
sharing a single Linear user, with per-project workflow versions and hooks. Settings and the
observability pages (Runs, Events, Workers) are project-aware.

## Quick Start

Requirements:

- `mise`
- PostgreSQL 17 or another supported PostgreSQL server
- Linear personal API token in `LINEAR_API_KEY`
- Codex CLI available to the runtime user

```bash
git clone https://github.com/VikingMew/symphony
cd symphony
mise trust
mise install
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony
mise exec -- mix setup
mise exec -- mix symphony.migrate
mise exec -- mix build
mise exec -- ./bin/symphony --port 4000
```

Open [http://127.0.0.1:4000/](http://127.0.0.1:4000/), then configure:

1. Settings / Projects: Linear project slug and repository URL.
2. Settings / Workflow: active states, terminal states, transitions, bootstrap, hooks, polling, and routing.
3. Settings / Agents: base prompt, profile prompts, allowed updates, and target states.
4. Settings / Runtime: Codex command, sandbox, approval policy, workspace paths, and worker settings.
5. Settings / Import: optional workflow/profile package import with preview before applying.

If PostgreSQL has no active workflow version, Symphony starts in setup-required mode and does not listen for Linear work until Settings creates the first workflow.

On a fresh database, Symphony can also offer to import the checked-in `workflow.yml` and
`profiles.yml` as the first active workflow version. This is a one-time import prompt; the YAML
files do not become runtime sources. To skip it and remain in setup-required mode, start with:

```bash
mise exec -- ./bin/symphony --port 4000 --no-default-yaml-prompt
```

## Configuration

PostgreSQL is the durable runtime authority. On cold start Symphony publishes the active per-project
workflow/config state as one in-memory snapshot; normal config, dashboard, prompt, diagnostics, and
dispatch reads use that snapshot without querying PostgreSQL. Successful Settings mutations republish
before reporting success, and background external-change detection retains last-known-good state
during database stalls. `workflow.yml` and `profiles.yml` are import/export artifacts, not files
that Symphony watches at runtime.

Useful startup options:

```bash
mise exec -- ./bin/symphony \
  --port 4000 \
  --logs-root /path/to/logs
```

- `--port` enables the Phoenix dashboard and JSON API.
- `--logs-root` changes the runtime log directory (default: `./log`).
- `--no-default-yaml-prompt` disables the first-run package import prompt.

The split package is organized by concern: `workflow.yml` contains tracker, project, state,
transition, hook, polling, and execution settings; `profiles.yml` contains the base prompt and
agent profiles. A project repository URL is required before polling and agent work can begin.

Common environment variables:

| Variable | Purpose |
| --- | --- |
| `LINEAR_API_KEY` | Linear API access. |
| `GH_TOKEN` / `GITHUB_TOKEN` | GitHub REST fallback for PR lookup/creation when authenticated `gh` is unavailable. |
| `LINEAR_ASSIGNEE` | Optional default Linear assignee. |
| `DATABASE_URL` | Required PostgreSQL connection URL for startup, migrations, and cutover. |
| `SYMPHONY_DATABASE_POOL_SIZE` | PostgreSQL pool size; defaults to `5` locally and `10` in Compose. |
| `SYMPHONY_AUTH_ENABLED` | Enables username/password auth for the web UI/API. |
| `SYMPHONY_ADMIN_USERNAME` / `SYMPHONY_ADMIN_PASSWORD` | Simple local admin auth. |
| `SECRET_KEY_BASE` | Release session-signing secret; Compose requires at least 64 bytes. |
| `SYMPHONY_EXECUTION_MODE=worker` | Queue work for external workers instead of local Codex execution. |
| `SYMPHONY_WORKER_REGISTRATION_TOKEN` | Shared token used by worker API clients. |
| `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` | Used for Linear/Codex subprocess network access. |
| `SYMPHONY_TRUST_X_FORWARDED_HEADERS=true` | Trust reverse-proxy forwarded scheme/host/prefix headers. |
| `SYMPHONY_PUBLIC_URL` | Optional fixed public base URL behind a proxy. |

The centralized service checks `gh` in its own runtime `PATH`; an interactive shell installation
does not prove the service can use it. SSH workers still need branch-push credentials on the worker,
while PR lookup/creation runs at the Symphony service boundary and does not require the remote
workspace path to exist locally.

## Operating Modes

| Mode | Use When |
| --- | --- |
| Local centralized | One machine runs the dashboard and Codex against PostgreSQL. |
| Centralized with SSH hosts | Symphony coordinates work but launches Codex on configured SSH hosts. |
| Worker mode | Dashboard and queue are separated from external workers that claim tasks over HTTP. |
| Dashboard-first setup | Start with an empty database and create configuration through Settings. |

Centralized execution is the default and does not require registered workers.

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
| Issue status + recent outcome | `/api/v1/:issue_identifier` |
| Bounded persisted run/event history | `/api/v1/runs?issue_identifier=SYM-3` |
| Health probes | `/health/live`, `/health/ready` |

Logs are structured application logs. There is no TUI status surface.

## Deployment

Symphony does not need to own public TLS, certificate issuance, or a dedicated domain. Put it behind Nginx, Kubernetes Ingress, or another trusted proxy, and enable forwarded headers only at that boundary.

See [docs/deployment.md](docs/deployment.md) for Nginx, Kubernetes, WebSocket, health probe, and forwarded-header examples.

### Docker Compose

The root `compose.yaml` is the supported self-hosted stack. It builds a non-root OTP release image,
starts PostgreSQL on an internal network, runs migrations once, then starts Symphony after the
database is healthy. Copy `.env.example` to the ignored `.env`, replace all `change-me` values,
and start the stack:

```bash
cp .env.example .env
docker compose config
docker compose build
docker compose up -d
curl --fail http://127.0.0.1:4000/health/live
curl --fail http://127.0.0.1:4000/health/ready
```

The final image contains Codex CLI, `gh`, git, SSH, ripgrep, certificates, PostgreSQL clients, and
SQLite cutover tooling, but no Mix, compiler, or source checkout. The separate `worker` target
remains available for SSH-reachable Codex workers.

Builds accept `ELIXIR_IMAGE`, `NODE_IMAGE`, `APT_DEBIAN_MIRROR`, `APT_SECURITY_MIRROR`,
`NPM_REGISTRY`, and `HEX_MIRROR_URL` build arguments for internal registries and mirrors.
Standard proxy variables can be passed as Docker build arguments and, separately, as runtime
environment variables. See [docs/compose.md](docs/compose.md) for first start, credentials,
upgrades, backup/restore, legacy SQLite cutover, volume verification, restart testing, and rollback.

## Project Layout

- `lib/`: application code and Mix tasks.
- `test/`: ExUnit coverage for runtime behavior.
- `config/` and `priv/`: application configuration, migrations, and static assets.
- `docs/`: architecture, operations, feature designs, and the exec-plan ledger.
- `workflow.yml` and `profiles.yml`: example import/export workflow package.
- `bin/symphony`: command-line launcher.
- `.codex/`: repository-local Codex skills and setup helpers.

Elixir/OTP supervision manages the long-running scheduler and agent processes; Phoenix LiveView
provides the operator and settings surfaces, and Ecto persists runtime state in PostgreSQL.

## Development

```bash
mise exec -- mix test
mise exec -- mix test --cover
mise exec -- mix lint
mise exec -- mix exec_plans.check
```

The ordinary unit suite is database-free. Run the explicit PostgreSQL integration target only
against a disposable, already-created empty database:

```bash
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony_smoke
make pg-smoke
```

The main CI workflow runs `make all`, which includes setup, build, formatting check, lint, coverage, and dialyzer.

The live end-to-end suite creates disposable Linear resources and starts a real Codex session, so
run it only with explicit credentials:

```bash
export LINEAR_API_KEY=...
make MIX="mise exec -- mix" e2e
```

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` to a comma-separated host list to exercise existing SSH
workers. When unset, the SSH scenario starts two disposable local worker containers.

Exec plans are the implementation ledger:

- Active work: [docs/exec-plans/active](docs/exec-plans/active)
- Completed work: [docs/exec-plans/completed](docs/exec-plans/completed)
- Index and rules: [docs/exec-plans/README.md](docs/exec-plans/README.md)

## Documentation

- [docs/spec.md](docs/spec.md): language-agnostic service specification (overview; domain contracts in `docs/spec-*.md`).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): implementation architecture.
- [docs/design.md](docs/design.md): code structure overview and feature-design index.
- [docs/user-guide.zh-CN.md](docs/user-guide.zh-CN.md): Chinese operator guide.
- [docs/persistence_and_auth.md](docs/persistence_and_auth.md): PostgreSQL and auth details.
- [docs/compose.md](docs/compose.md): Compose, PostgreSQL operations, and SQLite cutover.
- [docs/deployment.md](docs/deployment.md): reverse proxy and Kubernetes deployment.
- [docs/documentation-alignment.md](docs/documentation-alignment.md): long-lived documentation alignment.
- [docs/long_term_direction.zh-CN.md](docs/long_term_direction.zh-CN.md): long-term direction.

## Project Status

Implemented:

- database-backed runtime configuration and workflow versions;
- Linear tracker integration, discovery helpers, and diagnostics;
- restricted Linear task tools for Codex sessions;
- Codex app-server orchestration;
- centralized, SSH-host, and worker-backed execution paths;
- workspace/source preparation and cleanup policy;
- persisted runs, events, agent turns, worker tasks, and analytics;
- health endpoints and reverse proxy support.

Still alpha:

- APIs and UI are changing quickly;
- PostgreSQL is the supported persistence backend;
- multi-tenant hardening is not a goal yet;
- operators should review prompts, skills, sandbox, approval policy, repository access, and worker trust boundaries before using it on important code.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
