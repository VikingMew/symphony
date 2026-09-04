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
- PostgreSQL-backed projects, current workflows, runtime settings, runs, events, agent turns, workers, tasks, leases, and workspace records.
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
              \-> Blocked --human recovery--> Ready / Needs Refinement Review / Canceled
```

`Refining`, `Ready`, and `In Progress` are agent-work states. `Needs Refinement Review` and
`Ready to Merge` and `Blocked` are human-review states and are never ordinarily dispatched. A
successful implementation handoff enqueues one separate durable, read-only review job for the
backend-resolved immutable PR head. During normal
control-plane reconciliation, Symphony checks the exact open PR handed off for `Ready to Merge`
issues. A definitive GitHub merge conflict moves the issue to persistent `Blocked`; unknown,
behind, CI, review, and transient API states leave it waiting. Symphony persists
a blocking decision before commenting and moving an issue to `Blocked`, so failed Linear writes or
a service restart cannot dispatch another Codex run. Implementation completion is
explicit: after Codex validates, commits, and pushes the exact Linear branch, Symphony finds or
opens the GitHub PR and only then moves the issue to `Ready to Merge`. A human merges on GitHub;
Linear's GitHub automation owns the final move to `Done`.

## Core Concepts

| Concept | Meaning |
| --- | --- |
| Project | A configured Linear project slug plus repository URL, default branch, checkout depth, workspace source policy, and optional hook overrides. |
| Workflow | Runtime policy: active states, terminal states, transitions, bootstrap behavior, hooks, polling, and execution settings. One current workflow exists per enabled project. |
| Agent profile | A stage-specific prompt and update policy, such as refinement or implementation. |
| Run | One persisted attempt to work an issue, including status, attempt, timing, failure reason, events, agent turns, and bounded worker validation/runtime/handoff evidence. Runs, issues, events, and worker tasks carry the originating `project_id`. |
| Workspace | The per-issue filesystem location where Codex works, isolated per repository so multiple projects stay separate. |
| Worker mode | Optional HTTP task-queue mode where external workers claim current-workflow execution snapshots and return bounded validation/runtime/handoff evidence through `/api/worker/v1/*`. |

Symphony maintains multiple projects concurrently: one Linear project + one repository each,
sharing a single Linear user, with per-project workflows and hooks. Settings and the
observability pages (Runs, Events, Workers) are project-aware.

### Execution worker image

The separately deployable execution worker is built without changing the Panel image:

```bash
docker build --target execution-worker \
  --build-arg SYMPHONY_WORKER_IMAGE=symphony-worker:0.1.0 \
  --build-arg SYMPHONY_WORKER_SOURCE_REVISION="$(git rev-parse HEAD)" \
  -t symphony-worker:0.1.0 .
```

The supported Compose stack exposes it only through the opt-in `execution-worker` profile; see
[the worker operations guide](docs/execution-worker-operations.md). Run it with
`SYMPHONY_PANEL_URL` and `SYMPHONY_WORKER_TOKEN`. The fixed non-root user owns
`/worker/workspaces`, `/worker/cache`, and `/worker/logs`; mount those roots and Codex credentials
explicitly. Pass `GH_TOKEN` or `GITHUB_TOKEN` with the least repository clone/push permissions the
workflow needs. The image rewrites GitHub SCP-style URLs to HTTPS and uses `gh` as the system
credential helper, so it needs no external Git config or GitHub SSH host-key injection. The claimed
opaque `execution` payload supplies repository/ref, ordered hooks, Codex,
required gates, and handoff commands. Its Codex section carries app-server settings and the
rendered prompt as structured data; the worker drives one JSON-RPC turn over stdio. The worker
never derives a missing required gate.

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
2. Settings / Workflow: active states, bootstrap, hooks, and polling. Routing and transitions are
   an immutable code contract.
3. Settings / Agents: base prompt, profile prompts, allowed updates, and target states.
4. Settings / Runtime: Codex command, sandbox, approval policy, workspace paths, and worker settings.
5. Settings / Import: optional workflow/profile package import with preview before applying.

If PostgreSQL has no workflow for an enabled project, Symphony starts in setup-required mode and does not listen for Linear work until Settings creates it.

On a fresh database, Symphony can also offer to import the checked-in `workflow.yml` and
`profiles.yml` as the first current workflow. This is a one-time import prompt; the YAML
files do not become runtime sources. To skip it and remain in setup-required mode, start with:

```bash
mise exec -- ./bin/symphony --port 4000 --no-default-yaml-prompt
```

## Configuration

PostgreSQL is the durable runtime authority for project settings and profiles; workflow routing is
an immutable code contract. On cold start Symphony publishes the active per-project
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

The split package is organized by concern: `workflow.yml` contains tracker, project, hook, polling,
and execution settings plus a non-runtime workflow-policy example; `profiles.yml` contains the base prompt and
agent profiles. A project repository URL is required before polling and agent work can begin.

Common environment variables:

| Variable | Purpose |
| --- | --- |
| `LINEAR_API_KEY` | Linear API access. |
| `GH_TOKEN` / `GITHUB_TOKEN` | GitHub clone/push and PR access through the image's `gh` credential integration. |
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

The root `compose.yaml` is the supported self-hosted stack. By default it builds the non-root OTP
release as `symphony:local`, starts PostgreSQL on an internal network, runs migrations once, then
starts Symphony after the database is healthy. Copy `.env.example` to the ignored `.env`, replace
all `change-me` values, and start the local-build stack:

```bash
cp .env.example .env
docker compose config
docker compose build
docker compose up -d
curl --fail http://127.0.0.1:4000/health/live
curl --fail http://127.0.0.1:4000/health/ready
```

CI publishes matching `ghcr.io/vikingmew/symphony` and
`ghcr.io/vikingmew/symphony-execution-worker` manifests for `linux/amd64` and `linux/arm64`.
Local Compose still builds both targets from source. For a published deployment, select immutable
references from the same workflow run and keep the worker source revision equal to its commit:

```bash
export SYMPHONY_IMAGE=ghcr.io/vikingmew/symphony:sha-0123456789abcdef0123456789abcdef01234567
export SYMPHONY_EXECUTION_WORKER_IMAGE=ghcr.io/vikingmew/symphony-execution-worker:sha-0123456789abcdef0123456789abcdef01234567
export SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567
docker compose -f compose.yaml -f compose.published.yaml pull
docker compose -f compose.yaml -f compose.published.yaml up -d
```

The final image contains Codex CLI, `gh`, git, SSH, ripgrep, certificates, PostgreSQL clients,
SQLite cutover tooling, and the repository-pinned Elixir quality-gate toolchain. The separate
`worker` target remains available for SSH-reachable Codex workers.

Builds pin Codex CLI to `0.150.1` through the shared `CODEX_VERSION` build argument, so the
`symphony`, SSH `worker`, and `execution-worker` targets use the same release. All three targets
also inherit mise `2025.8.16`, Erlang `28`, Elixir `1.19.5-otp-28`, Mix, Make, and native build
dependencies from one build-time stage. The language versions match `mise.toml`; mise links the
preinstalled runtimes during the image build, so `mise exec` does not install them in an issue
workspace. Mutable Mix, Hex, mise, and XDG-aware build-tool caches live under each target's
existing writable workspace/cache volume and remain usable with the read-only root filesystem.
Builds also accept
`ELIXIR_IMAGE`, `NODE_IMAGE`, `APT_DEBIAN_MIRROR`, `APT_SECURITY_MIRROR`, `NPM_REGISTRY`, and
`HEX_MIRROR_URL` build arguments for internal registries and mirrors.
Standard proxy variables can be passed as Docker build arguments and, separately, as runtime
environment variables. See [docs/compose.md](docs/compose.md) for first start, credentials,
published-image authentication and inspection, upgrades, backup/restore, legacy SQLite cutover,
volume verification, restart testing, and rollback.

## Project Layout

- `lib/`: application code and Mix tasks.
- `test/`: ExUnit coverage for runtime behavior.
- `config/` and `priv/`: application configuration, migrations, and static assets.
- `docs/`: architecture, operations, feature designs, and governance.
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
```

The ordinary unit suite is database-free. Run the explicit PostgreSQL integration target only
against a disposable, already-created empty database:

```bash
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony_smoke
mise exec -- mix symphony.postgres_smoke
```

Make is reserved for build and image targets. Run quality checks independently with
`scripts/check.sh` (format, lint, compile), `scripts/unit.sh` (85% coverage-bearing unit suite),
`scripts/e2e.sh` (credentialed live integration suite), and `scripts/dialyzer.sh` (static analysis).
CI orchestrates these scripts into fast, unit, E2E, and static jobs; publication uses only the fast
check gate.

The live end-to-end suite creates disposable Linear resources and starts a real Codex session, so
run it only with explicit credentials:

```bash
export LINEAR_API_KEY=...
scripts/e2e.sh
```

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` to a comma-separated host list to exercise existing SSH
workers. When unset, the SSH scenario starts two disposable local worker containers.

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

- database-backed runtime configuration and current workflows;
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
