# Symphony Architecture Design

## 1. Overview

Symphony is an orchestration service for autonomous coding-agent work. It continuously reads work
items from an issue tracker, creates an isolated workspace for each eligible issue, starts a Codex
App Server session in that workspace, and lets the agent execute the repository-defined workflow.

The repository contains two major parts:

- `SPEC.md`: language-agnostic service specification.
- `elixir/`: experimental Elixir/OTP reference implementation.

The current implementation targets Linear as the tracker and Codex App Server as the coding-agent
runtime.

## 2. Goals

- Poll project work from Linear on a fixed cadence.
- Dispatch eligible issues with bounded concurrency.
- Create and preserve isolated per-issue workspaces.
- Run lifecycle hooks to prepare and clean workspaces.
- Launch Codex App Server sessions with issue-specific prompts.
- Keep runtime behavior configurable through an in-repository `WORKFLOW.md`.
- Provide logs, JSON state APIs, and an optional Phoenix LiveView dashboard.
- Stop or clean up active runs when issue states become terminal.

## 3. Non-Goals

- Symphony is not a general-purpose workflow engine.
- Symphony is not a multi-tenant control plane.
- Symphony does not implement project-specific ticket or PR policy in code; that policy belongs in
  `WORKFLOW.md` and agent skills.
- Symphony does not replace the coding agent. It schedules, isolates, prompts, and observes agent
  work.

## 4. High-Level Architecture

```mermaid
flowchart TD
    linear[Linear Project / Issues] -->|poll eligible issues| tracker[Tracker Layer]
    tracker --> orchestrator[Orchestrator]

    workflow[WORKFLOW.md] --> loader[Workflow Loader]
    loader --> config[Config Layer]
    config --> orchestrator

    orchestrator -->|create/reuse| workspace[Workspace Manager]
    workspace --> issuews[Per-Issue Workspace]
    issuews -->|after_create hook| bootstrap[Clone repo / install dependencies]

    orchestrator -->|start run| runner[Agent Runner]
    runner --> appserver[Codex App Server Client]
    appserver --> codex[Codex Coding Agent]

    codex -->|read/write files, run tests, git| issuews
    codex -->|linear_graphql tool| linear
    codex -->|branches, commits, PRs| github[GitHub]

    orchestrator --> state[Runtime State]
    orchestrator --> logs[Structured Logs]
    orchestrator --> http[Optional Phoenix HTTP Server]
    http --> dashboard[LiveView Dashboard]
    http --> api[JSON API]
```

## 5. Runtime Flow

```mermaid
sequenceDiagram
    participant CLI as bin/symphony
    participant Workflow as WORKFLOW.md
    participant Orch as Orchestrator
    participant Linear as Linear API
    participant WS as Workspace
    participant Codex as Codex App Server
    participant GitHub as GitHub

    CLI->>Workflow: Read YAML front matter and prompt body
    CLI->>Orch: Start application supervision tree

    loop polling interval
        Orch->>Linear: Fetch active candidate issues
        Linear-->>Orch: Return normalized issues
        Orch->>Orch: Apply concurrency, state, retry, and blocker rules
        Orch->>WS: Ensure issue workspace exists
        WS->>WS: Run after_create hook when newly created
        Orch->>Codex: Launch app-server session
        Orch->>Codex: Send rendered issue prompt
        Codex->>WS: Modify code, run validation, commit changes
        Codex->>Linear: Update issue comments and status through tools
        Codex->>GitHub: Push branch and create/update PR
        Codex-->>Orch: Return turn result
        Orch->>Orch: Continue, retry, release, stop, or clean up
    end
```

## 6. Main Components

### 6.1 CLI

Location: `elixir/lib/symphony_elixir/cli.ex`

The CLI is the escript entrypoint built as `elixir/bin/symphony`. It accepts:

- an optional workflow file path, defaulting to `./WORKFLOW.md`
- `--logs-root <path>` to choose the log output root
- `--port <port>` to enable the Phoenix observability server
- `--i-understand-that-this-will-be-running-without-the-usual-guardrails` to acknowledge preview
  runtime behavior

The CLI validates the workflow path, stores runtime overrides, and starts the Elixir application.

### 6.2 Workflow Loader

Locations:

- `elixir/lib/symphony_elixir/workflow.ex`
- `elixir/lib/symphony_elixir/workflow_store.ex`

The workflow loader reads `WORKFLOW.md`, parses YAML front matter, and keeps the Markdown body as the
prompt template. Symphony keeps running with the last known good workflow if a later reload fails.

### 6.3 Config Layer

Locations:

- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`

The config layer applies defaults and converts workflow settings into typed runtime values. It
handles tracker settings, polling interval, workspace paths, hooks, agent concurrency, Codex command
settings, sandbox settings, and optional server settings.

### 6.4 Tracker Layer

Locations:

- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/lib/symphony_elixir/tracker/memory.ex`
- `elixir/lib/symphony_elixir/linear/adapter.ex`
- `elixir/lib/symphony_elixir/linear/client.ex`
- `elixir/lib/symphony_elixir/linear/issue.ex`

The tracker layer normalizes external issue data into Symphony's internal issue model. The Linear
adapter fetches candidate issues, fetches issue state for reconciliation, and identifies terminal
issues during cleanup.

### 6.5 Orchestrator

Locations:

- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`

The orchestrator owns the runtime loop. It polls the tracker, dispatches issues, enforces
concurrency, tracks active runs, handles retries, releases completed work, stops ineligible work,
and publishes status information.

### 6.6 Workspace Manager

Locations:

- `elixir/lib/symphony_elixir/workspace.ex`
- `elixir/lib/symphony_elixir/path_safety.ex`

The workspace manager maps issue identifiers to deterministic filesystem paths. It creates
workspaces, runs lifecycle hooks, and removes workspaces for terminal issues. Workspace isolation is
central to Symphony's execution model: each agent operates inside the issue-specific repository
copy.

### 6.7 Agent Runner

Locations:

- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`

The agent runner prepares the prompt for a specific issue and starts the Codex App Server client. It
reports run lifecycle events and outcomes back to the orchestrator.

### 6.8 Codex App Server Integration

Locations:

- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`

This layer launches and communicates with Codex App Server. It also exposes a client-side
`linear_graphql` dynamic tool so repository skills can make raw Linear GraphQL calls during agent
sessions.

### 6.9 Observability

Locations:

- `elixir/lib/symphony_elixir/log_file.ex`
- `elixir/lib/symphony_elixir/http_server.ex`
- `elixir/lib/symphony_elixir_web/*`

Symphony exposes runtime visibility through structured logs and an optional Phoenix service. When a
port is configured, the service provides:

- `/`: LiveView dashboard
- `/api/v1/state`: full state snapshot
- `/api/v1/<issue_identifier>`: issue-specific state
- `/api/v1/refresh`: manual refresh endpoint

## 7. Configuration Model

`WORKFLOW.md` is the operational contract. It contains YAML front matter plus a Markdown prompt.

Example:

```md
---
tracker:
  kind: linear
  project_slug: "example-project"
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}
Description: {{ issue.description }}
```

Important configuration areas:

- `tracker`: Linear project, API key, active states, terminal states.
- `polling`: poll interval.
- `workspace`: root directory for per-issue workspaces.
- `hooks`: shell commands for workspace lifecycle events.
- `agent`: concurrency and turn limits.
- `codex`: app-server command, approval policy, sandbox settings.
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
- branch, commit, and PR operations
- reviewer feedback handling

This split keeps Symphony generic while allowing teams to encode project-specific execution policy in
`WORKFLOW.md` and repository skills.

## 9. Failure Handling

Symphony is designed for long-running operation and transient failure recovery:

- Invalid startup workflow configuration prevents boot.
- Invalid workflow reloads are logged, while the last known good workflow remains active.
- Failed agent turns can be retried according to orchestrator policy.
- Active runs are stopped when issue states become terminal or ineligible.
- Terminal issues trigger cleanup of matching workspaces.
- Runtime details are written to logs and exposed through the optional status API.

## 10. Security and Trust Model

The Elixir implementation is explicitly marked as prototype software for trusted environments. It can
launch Codex with broad authority depending on `WORKFLOW.md` configuration.

Security-sensitive controls include:

- Codex command and inherited environment variables.
- Workspace root and lifecycle hooks.
- Codex approval policy.
- Codex thread and turn sandbox settings.
- Credentials such as `LINEAR_API_KEY`, GitHub auth, SSH keys, and Codex auth.

Operators should review `WORKFLOW.md` before running Symphony and should avoid using this preview
implementation in untrusted repositories or untrusted host environments.

## 11. Running Locally

Install project tool versions with `mise`:

```bash
cd elixir
mise trust
mise install
```

Install dependencies and build the executable:

```bash
mise exec -- mix setup
mise exec -- mix build
```

Run without the dashboard:

```bash
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

Run with the dashboard:

```bash
export LINEAR_API_KEY=...
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

Run checks:

```bash
cd elixir
mise exec -- make all
```

## 12. Extension Points

Common extension areas:

- Add another tracker adapter behind the tracker abstraction.
- Customize issue-state policy in `WORKFLOW.md`.
- Add workspace hooks for project-specific setup and teardown.
- Add repository-local Codex skills for commit, push, PR, Linear, or release workflows.
- Extend the Phoenix dashboard or JSON API for operator needs.
- Implement another language runtime from `SPEC.md` while keeping the same architecture boundaries.

## 13. Repository Map

```text
.
├── README.md
├── SPEC.md
├── ARCHITECTURE.md
└── elixir
    ├── README.md
    ├── WORKFLOW.md
    ├── Makefile
    ├── mise.toml
    ├── mix.exs
    ├── lib
    │   ├── symphony_elixir
    │   └── symphony_elixir_web
    └── test
```

