---
title: Symphony Architecture Design
genre: architecture
domain: [architecture, runtime]
status: current
language: en
updated: 2026-08-27
owner: SymphonyElixir.Orchestrator
---

# Symphony Architecture Design

## 1. Overview

Symphony is an orchestration service for autonomous coding-agent work. It continuously reads work
items from an issue tracker, creates an isolated workspace for each eligible issue, starts a Codex
App Server session in that workspace, and lets the agent execute the repository-defined workflow.

The repository contains two major parts:

- `SPEC.md`: language-agnostic service specification.
- The repository root is the Elixir/Phoenix implementation.

The current implementation targets Linear as the tracker and Codex App Server as the coding-agent
runtime.

## 2. Goals

- Poll project work from Linear on a fixed cadence.
- Dispatch eligible issues with bounded concurrency.
- Create and preserve isolated per-issue workspaces.
- Run lifecycle hooks to prepare and clean workspaces.
- Launch Codex App Server sessions with issue-specific prompts.
- Keep runtime behavior configurable through each project's current PostgreSQL workflow.
- Persist projects, workflows, issues, runs, agent turns, workspaces, worker tasks, leases,
  and events in PostgreSQL when the Repo is available.
- Provide logs, JSON state APIs, Linear diagnostics, worker APIs, and a Phoenix LiveView dashboard.
- Stop or clean up active runs when issue states become terminal.

## 3. Non-Goals

- Symphony is not a general-purpose workflow engine.
- Symphony is not a multi-tenant control plane.
- Symphony does not implement project-specific ticket or PR policy in code; that policy belongs in
  Settings-managed workflow/profile configuration and agent skills.
- Symphony does not replace the coding agent. It schedules, isolates, prompts, and observes agent
  work.

## 4. High-Level Architecture

```mermaid
flowchart TD
    linear[Linear Project / Issues] -->|poll eligible issues| tracker[Tracker Layer]
    tracker --> orchestrator[Orchestrator]

    workflow[Current PostgreSQL Workflow] --> loader[Workflow Store]
    loader --> config[Config Layer]
    config --> orchestrator
    orchestrator --> postgres[(PostgreSQL / Ecto)]

    orchestrator -->|create/reuse| workspace[Workspace Manager]
    workspace --> issuews[Per-Issue Workspace]
    issuews -->|after_create hook| bootstrap[Clone repo / install dependencies]

    orchestrator -->|centralized mode: start run| runner[Agent Runner]
    runner --> appserver[Codex App Server Client]
    appserver --> codex[Codex Coding Agent]
    orchestrator -->|worker mode: enqueue task| workerapi[Worker Task Queue / HTTP API]
    extworker[External Worker] -->|register / claim / heartbeat / events| workerapi

    codex -->|read/write files, run tests, git| issuews
    codex -->|restricted task tools| linear
    codex -->|branches, commits, PRs| github[GitHub]

    orchestrator --> state[Runtime State]
    orchestrator --> logs[Structured Logs]
    orchestrator --> http[Optional Phoenix HTTP Server]
    http --> dashboard[LiveView Dashboard]
    http --> api[JSON API]
    http --> workerapi
```

## 5. Runtime Flow

```mermaid
sequenceDiagram
    participant CLI as bin/symphony
    participant Workflow as PostgreSQL Workflow Store
    participant Orch as Orchestrator
    participant Linear as Linear API
    participant WS as Workspace
    participant Codex as Codex App Server
    participant GitHub as GitHub

    CLI->>Workflow: Select active database workflow source
    CLI->>Orch: Start application supervision tree

    loop polling interval
        Orch->>Workflow: Resolve enabled projects' workflows
        Orch->>Linear: Fetch active candidate issues per project
        Linear-->>Orch: Return normalized issues
        Orch->>Orch: Apply concurrency, state, retry, and blocker rules per project
        alt centralized execution
            Orch->>WS: Ensure issue workspace exists
            WS->>WS: Run after_create hook when newly created
            Orch->>Codex: Launch app-server session
            Orch->>Codex: Send rendered issue prompt
            Codex->>WS: Modify code, validate, and commit exact Linear branch
            Codex->>GitHub: Push exact Linear branch
            Codex->>Orch: Explicitly request Ready to Merge with final result
            Orch->>GitHub: Find or create open PR for repository/base/head
            Orch->>Linear: Attach PR, post final comment, move to Ready to Merge
            Codex-->>Orch: Return turn result
        else worker execution
            Orch->>Orch: Persist run/task in PostgreSQL
            Orch->>Orch: External worker claims task through HTTP API
            Orch->>Codex: Worker launches app-server and sends one JSON-RPC turn
            Codex-->>Orch: Worker reports session, validation, and handoff evidence
        end
        Orch->>Orch: Continue, retry, release, stop, or clean up
    end
```

## 6. Main Components

### 6.1 CLI

Location: `lib/symphony_elixir/cli.ex`

The CLI is the local-development entrypoint built as `bin/symphony`. It accepts:

- `--logs-root <path>` to choose the log output root
- `--port <port>` to enable the Phoenix observability server

The CLI stores runtime overrides, requires `DATABASE_URL`, applies PostgreSQL migrations, and
starts the Elixir application. Production containers start the real OTP release after a separate
one-shot release migration command. If no current workflow exists, Symphony enters
setup-required mode and the Settings UI creates the first active workflow.

### 6.2 Workflow Loader

Locations:

- `lib/symphony_elixir/workflow.ex`
- `lib/symphony_elixir/workflow_store.ex`

PostgreSQL remains the durable workflow authority. At cold start the workflow store loads every enabled
project and atomically publishes one coherent in-memory snapshot containing the workflow map,
default selection, source/version metadata, and setup/error state. `current/0`,
`current_with_source/0`, `list_enabled/0`, and `for_project/1` read only that published term; they do
not query PostgreSQL or wait behind refresh work. Explicit mutations persist first and publish before
success, while a single background refresh detects external activation and rejects stale results by
generation. Failures retain the complete last-known-good snapshot.

If no enabled project has an active workflow, the published setup-required snapshot does not poll
Linear or schedule agents. Workspace isolation is per repository, which keeps multiple projects'
workspaces separate.

### 6.3 Config Layer

Locations:

- `lib/symphony_elixir/config.ex`
- `lib/symphony_elixir/config/schema.ex`

The config layer applies defaults and converts workflow settings into typed runtime values. It
handles tracker settings, polling interval, workspace paths, hooks, agent concurrency, Codex command
settings, sandbox settings, worker SSH host settings, and optional server settings.

### 6.4 Tracker Layer

Locations:

- `lib/symphony_elixir/tracker.ex`
- `lib/symphony_elixir/linear/adapter.ex`
- `lib/symphony_elixir/linear/client.ex`
- `lib/symphony_elixir/linear/issue.ex`

The tracker layer normalizes external issue data into Symphony's internal issue model. The Linear
adapter fetches candidate issues, fetches issue state for reconciliation, and identifies terminal
issues during cleanup.

### 6.5 Orchestrator

Locations:

- `lib/symphony_elixir/orchestrator.ex`
- `lib/symphony_elixir/status_dashboard.ex`

The orchestrator owns the runtime loop. It polls the tracker, dispatches issues, enforces
concurrency, tracks active runs, handles retries, releases completed work, stops ineligible work,
and publishes status information. In centralized mode it starts `AgentRunner` locally or over
configured SSH hosts. In worker mode it persists worker tasks and lets external workers claim them
through `/api/worker/v1/*`.

### 6.6 Workspace Manager

Locations:

- `lib/symphony_elixir/workspace.ex`
- `lib/symphony_elixir/path_safety.ex`

The workspace manager maps issue identifiers to deterministic filesystem paths. It creates
workspaces, runs lifecycle hooks, and removes workspaces for terminal issues. Workspace isolation is
central to Symphony's execution model: each agent operates inside the issue-specific repository
copy. In centralized SSH-host execution, workspace preparation and hooks run on the selected SSH
host.

### 6.7 Agent Runner

Locations:

- `lib/symphony_elixir/agent_runner.ex`
- `lib/symphony_elixir/prompt_builder.ex`

The agent runner prepares the prompt for a specific issue and starts the Codex App Server client. It
reports run lifecycle events and outcomes back to the orchestrator. For centralized implementation
runs it also owns the atomic GitHub handoff boundary: validate repository/default/head identity,
ensure an open PR exists, record its URL, then allow the restricted Linear tool to move the issue
to `Ready to Merge`. This boundary uses repository metadata and remote branch state, not the local
workspace path, so it also works when Codex ran on an SSH host.

### 6.8 Codex App Server Integration

Locations:

- `lib/symphony_elixir/codex/app_server.ex`
- `lib/symphony_elixir/codex/dynamic_tool.ex`

This layer launches and communicates with Codex App Server. It exposes restricted task-scoped
Linear tools (`linear_task_read` and `linear_task_update`) plus the implementation-only
`create_pull_request` tool. Raw Linear GraphQL and GitHub credentials remain internal Symphony
backend details and are not Codex-visible workflow credentials.
The implementation completion request is special: `Ready to Merge` is accepted only with final
comment/result/references containing the PR URL returned by a successful same-session tool call,
and `AgentRunner` must prepare the GitHub PR before any Linear completion write. A normal turn exit
or exhausted turn budget is not an implementation-completion signal.

### 6.9 Observability

Locations:

- `lib/symphony_elixir/log_file.ex`
- `lib/symphony_elixir/http_server.ex`
- `lib/symphony_elixir_web/*`

Symphony exposes runtime visibility through structured logs and an optional Phoenix service. When a
port is configured, the service provides:

- `/`: LiveView dashboard
- `/api/v1/state`: full state snapshot
- `/api/v1/<issue_identifier>`: live issue state augmented by bounded persisted history, with an
  inactive persisted issue fallback
- `/api/v1/runs?issue_identifier=<identifier>`: bounded newest-first runs and event timeline
- `/api/v1/refresh`: manual refresh endpoint
- `/runs`, `/events`, `/workers`, `/settings/*`: management pages
- `/settings/import`: staged split-package import and diff review before applying to editable Settings draft
- `/diagnostics/linear`: validation for the active Linear runtime configuration

### 6.10 Persistence and Worker API

Locations:

- `lib/symphony_elixir/persistence.ex`
- `lib/symphony_elixir/persistence/*`
- `lib/symphony_elixir_web/controllers/worker_api_controller.ex`

The persistence context owns PostgreSQL-backed records for projects, workflows, runs, agent
turns, workspaces, worker identities, worker sessions, worker tasks, task leases, and events. The
worker API supports registration, task claim, heartbeat/lease renewal, and task event reporting.
Worker registration requires `SYMPHONY_WORKER_REGISTRATION_TOKEN`.
The supported Compose deployment optionally runs the trusted HTTP runtime as `execution-worker`,
on a control network shared with the Panel and a worker-only egress network. It has separate
workspace, cache, log, and Codex volumes and no database-network membership or PostgreSQL secret.
Claimed tasks carry the rendered prompt and app-server settings as structured data. The worker
uses the same `Codex.AppServer` JSON-RPC stdio client as centralized execution for one session and
turn, while hooks, required gates, and handoff remain shell-command phases.
This is distinct from the SSH `worker` image target. Centralized execution remains the default.

The observability boundary deliberately separates memory/current from persistence/history:
`/api/v1/state` reads only the orchestrator snapshot, while issue enrichment and `/api/v1/runs`
use bounded tasks through `PersistenceProvider` and Repo. A stalled history query can fail its own
request without occupying `WorkflowStore`, `Orchestrator`, or `StatusDashboard`.

## 7. Configuration Model

The current workflow is a single PostgreSQL-backed row per project. Operators create and update it in
place through the Settings UI; startup can enter setup-required mode when no current workflow exists.
`workflow.yml` and `profiles.yml` are split package artifacts for import/export and examples, not
startup authority.

Important configuration areas:

- `tracker`: Linear project, API key, active states, terminal states.
- `polling`: poll interval.
- `workspace`: root directory for per-issue workspaces.
- `hooks`: shell commands for workspace lifecycle events.
- `agent`: concurrency and turn limits.
- `codex`: app-server command, approval policy, sandbox settings.
- `worker`: SSH host routing for centralized remote execution.
- `server`: optional dashboard/API port.

## 8. State and Ownership Boundaries

Symphony owns:

- polling cadence
- issue eligibility checks
- per-issue workspace creation
- process supervision
- retry scheduling
- run status and observability

The agent owns, through the workflow prompt and tools:

- implementation changes
- tests and validation
- Linear workpad comments
- Linear state transitions
- exact Linear branch commits and pushes
- updates to the same branch/PR after human change requests
- reviewer feedback handling

Codex requests initial PR lookup/creation through `create_pull_request`; Symphony owns its centralized
backend and credentials. It never approves
or merges that PR and never pushes a feature result to the configured default branch. GitHub review
and Linear's merged-PR automation own `Ready to Merge -> Done`.

This split keeps Symphony generic while allowing teams to encode shared execution policy in Settings
and repository skills. Project-specific repository and Linear slug values live in project settings,
while workflow routing and agent policy remain shared.

## 9. Failure Handling

Symphony is designed for long-running operation and transient failure recovery:

- Missing startup workflow configuration enters setup-required mode instead of polling Linear.
- Dashboard-first `--port` mode can boot without an active workflow, so the first workflow can be
  created through `/settings/workflow`.
- Invalid workflow reloads are logged, while the last known good database workflow remains active.
- Failed agent turns can be retried according to orchestrator policy.
- Active runs are stopped when issue states become terminal or ineligible.
- Terminal issues trigger cleanup of matching workspaces.
- Runtime details are written to logs and exposed through the optional status API.
- Input-required, approval-required, and MCP elicitation outcomes are blocked sessions, not normal
  retry failures. They remain claimed and visible in snapshot/API/dashboard until issue state or
  routing changes release the claim.

## 9.1 Operational Surfaces

Operator-facing deployment and history surfaces are current architecture:

- `/analytics` owns historical time-range statistics; dashboard state remains a live operational
  view, while `/runs` and `/events` provide persisted per-run and audit views.
- The root Compose stack runs PostgreSQL, a one-shot migration release, and the non-root Symphony
  release. Public TLS, domains, and ingress policy remain the responsibility of the trusted edge;
  see [compose.md](compose.md) and [deployment.md](deployment.md).

## 10. Security and Trust Model

The Elixir implementation is explicitly marked as prototype software for trusted environments. It can
launch Codex with broad authority depending on Settings-managed workflow configuration.

Security-sensitive controls include:

- Codex command and inherited environment variables.
- Workspace root and lifecycle hooks.
- Codex approval policy.
- Codex thread and turn sandbox settings.
- Credentials such as `LINEAR_API_KEY`, GitHub auth, SSH keys, and Codex auth.

Operators should review Settings-managed workflow/runtime configuration before enabling listening,
and should avoid using this preview implementation in untrusted repositories or untrusted host
environments.

## 11. Running Locally

Install project tool versions with `mise`:

```bash
mise trust
mise install
```

Install dependencies and build the executable:

```bash
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony
mise exec -- mix setup
mise exec -- mix symphony.migrate
mise exec -- mix build
```

Run without the dashboard:

```bash
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony
```

Run with the dashboard:

```bash
export DATABASE_URL=postgresql://symphony:password@127.0.0.1:5432/symphony
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony --port 4000
```

Run checks:

```bash
mise exec -- make all
```

## 12. Extension Points

Common extension areas:

- Add another tracker adapter behind the tracker abstraction.
- Customize issue-state policy in Settings / Workflow.
- Add workspace hooks for project-specific setup and teardown.
- Add repository-local Codex skills for commit, push, PR, Linear, or release workflows.
- Extend the Phoenix dashboard or JSON API for operator needs.
- Implement another language runtime from `SPEC.md` while keeping the same architecture boundaries.

## 13. Repository Map

```text
.
├── README.md
├── Dockerfile
├── compose.yaml
├── docs/examples/workflow.yml
├── docs/examples/profiles.yml
├── Makefile
├── mise.toml
├── mix.exs
├── config
├── docs
├── lib
│   ├── symphony_elixir
│   └── symphony_elixir_web
├── priv
└── test
```
