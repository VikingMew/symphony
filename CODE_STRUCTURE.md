# Symphony Code Structure

This document explains how the repository is organized and where to start when reading or changing
the code.

## 1. Repository Layout

```text
.
├── README.md
├── SPEC.md
├── ARCHITECTURE.md
├── CODE_STRUCTURE.md
├── LICENSE
├── NOTICE
├── .codex/
│   ├── skills/
│   └── worktree_init.sh
└── elixir/
    ├── README.md
    ├── workflow.yml
    ├── profiles.yml
    ├── AGENTS.md
    ├── Makefile
    ├── mise.toml
    ├── mix.exs
    ├── mix.lock
    ├── config/
    ├── docs/
    ├── lib/
    ├── priv/
    └── test/
```

Root-level files describe the product and its language-agnostic contract. The executable reference
implementation lives under `elixir/`.

## 2. Root Files

| Path | Purpose |
| --- | --- |
| `README.md` | Product overview and pointer to the Elixir implementation. |
| `SPEC.md` | Language-independent Symphony service specification. |
| `ARCHITECTURE.md` | High-level architecture and runtime design. |
| `CODE_STRUCTURE.md` | Code-oriented map of the repository. |
| `.codex/skills/*` | Repository-local Codex skills used by the workflow prompt. |
| `.codex/worktree_init.sh` | Helper script for Codex worktree initialization. |

## 3. Elixir Project Root

```text
elixir/
├── README.md
├── workflow.yml
├── profiles.yml
├── AGENTS.md
├── Makefile
├── mise.toml
├── mix.exs
├── mix.lock
├── config/config.exs
├── lib/
└── test/
```

| Path | Purpose |
| --- | --- |
| `elixir/README.md` | Setup, run, configuration, testing, and FAQ for the Elixir implementation. |
| `elixir/workflow.yml` | Example/import package for shared workflow routing and runtime settings. |
| `elixir/profiles.yml` | Example/import package for shared base prompt and agent profiles. |
| `elixir/AGENTS.md` | Agent-facing repository guidance. |
| `elixir/Makefile` | Common development targets such as `test`, `lint`, `coverage`, `ci`, and `e2e`. |
| `elixir/mise.toml` | Required runtime tool versions: Erlang 28 and Elixir 1.19.5 OTP 28. |
| `elixir/mix.exs` | Mix project definition, dependencies, aliases, and escript build config. |
| `elixir/config/config.exs` | Phoenix/Bandit endpoint and JSON configuration. |
| `elixir/priv/repo/migrations` | SQLite/Ecto migrations. |
| `elixir/docs` | Operator, design, logging, token accounting, and completed plan docs. |

## 4. Application Startup

Primary files:

- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/cli.ex`

`SymphonyElixir.CLI` is the command-line entrypoint compiled into `elixir/bin/symphony`. It parses
runtime CLI options such as `--port` and `--db`, stores runtime overrides, and starts the OTP
application. Workflow authority is loaded from the SQLite active workflow version rather than a
startup workflow path.

`SymphonyElixir.Application` is defined in `elixir/lib/symphony_elixir.ex`. It starts the supervision
tree:

```text
SymphonyElixir.Supervisor
├── SymphonyElixir.Repo (skipped in MIX_ENV=test)
├── Phoenix.PubSub
├── Task.Supervisor
├── SymphonyElixir.WorkflowStore
├── SymphonyElixir.Orchestrator
├── SymphonyElixir.HttpServer
└── SymphonyElixir.StatusDashboard
```

The plain `SymphonyElixir` module is a small convenience wrapper around
`SymphonyElixir.Orchestrator.start_link/1`.

## 5. Core Runtime Modules

```text
elixir/lib/symphony_elixir/
├── agent_runner.ex
├── cli.ex
├── config.ex
├── config/schema.ex
├── http_server.ex
├── log_file.ex
├── orchestrator.ex
├── path_safety.ex
├── persistence.ex
├── persistence/
├── persistence_provider.ex
├── prompt_builder.ex
├── repo.ex
├── specs_check.ex
├── ssh.ex
├── status_dashboard.ex
├── tracker.ex
├── workflow.ex
├── workflow_store.ex
└── workspace.ex
```

| Module | File | Responsibility |
| --- | --- | --- |
| `SymphonyElixir.Application` | `symphony_elixir.ex` | OTP application entrypoint and supervision tree. |
| `SymphonyElixir.CLI` | `cli.ex` | CLI parsing, runtime overrides, and app startup. |
| `SymphonyElixir.Workflow` | `workflow.ex` | Workflow package parsing and config/prompt normalization entrypoints. |
| `SymphonyElixir.WorkflowStore` | `workflow_store.ex` | Keeps current workflow state and last known good configuration. |
| `SymphonyElixir.Config` | `config.ex` | Typed accessors for workflow configuration and defaults. |
| `SymphonyElixir.Config.Schema` | `config/schema.ex` | Configuration schema and validation rules. |
| `SymphonyElixir.Orchestrator` | `orchestrator.ex` | Polling, dispatch, active-run tracking, retries, cleanup, status generation. |
| `SymphonyElixir.Tracker` | `tracker.ex` | Tracker behavior/abstraction used by the orchestrator. |
| `SymphonyElixir.Workspace` | `workspace.ex` | Workspace path resolution, creation, hooks, and cleanup. |
| `SymphonyElixir.PathSafety` | `path_safety.ex` | Path validation helpers for workspace safety. |
| `SymphonyElixir.AgentRunner` | `agent_runner.ex` | Creates prompts and runs Codex App Server sessions for issues. |
| `SymphonyElixir.PromptBuilder` | `prompt_builder.ex` | Renders issue data into the workflow prompt template. |
| `SymphonyElixir.HttpServer` | `http_server.ex` | Starts optional Phoenix/Bandit observability HTTP server. |
| `SymphonyElixir.StatusDashboard` | `status_dashboard.ex` | Terminal/operator status rendering. |
| `SymphonyElixir.LogFile` | `log_file.ex` | Runtime log file configuration and writing. |
| `SymphonyElixir.Persistence` | `persistence.ex` | SQLite-backed projects, workflows, runs, tasks, workers, leases, and events. |
| `SymphonyElixir.PersistenceProvider` | `persistence_provider.ex` | Runtime indirection for persistence fakes in tests. |
| `SymphonyElixir.Repo` | `repo.ex` | Ecto repository. |
| `SymphonyElixir.SSH` | `ssh.ex` | SSH worker support. |
| `SymphonyElixir.SpecsCheck` | `specs_check.ex` | Internal spec consistency checks. |

## 6. Tracker and Linear Integration

```text
elixir/lib/symphony_elixir/linear/
├── adapter.ex
├── client.ex
├── diagnostics.ex
├── discovery.ex
├── issue.ex
├── workflow_bootstrap.ex
└── workflow_state_validator.ex
```

| Module | File | Responsibility |
| --- | --- | --- |
| `SymphonyElixir.Linear.Adapter` | `linear/adapter.ex` | Implements the tracker interface for Linear. |
| `SymphonyElixir.Linear.Client` | `linear/client.ex` | Low-level Linear API calls. |
| `SymphonyElixir.Linear.Diagnostics` | `linear/diagnostics.ex` | Read-only validation for active Linear runtime configuration. |
| `SymphonyElixir.Linear.Discovery` | `linear/discovery.ex` | Read-only Linear metadata used by Settings while configuring projects and workflow states. |
| `SymphonyElixir.Linear.Issue` | `linear/issue.ex` | Normalized issue struct/model. |
| `SymphonyElixir.Linear.WorkflowBootstrap` | `linear/workflow_bootstrap.ex` | Explicit creation of missing Linear workflow states from diagnostics. |
| `SymphonyElixir.Linear.WorkflowStateValidator` | `linear/workflow_state_validator.ex` | Compares configured Symphony states with Linear team states. |

The orchestrator depends on the tracker abstraction, not directly on Linear. This keeps the core
dispatch logic separate from external API details.

## 7. Codex Integration

```text
elixir/lib/symphony_elixir/codex/
├── app_server.ex
└── dynamic_tool.ex
```

| Module | File | Responsibility |
| --- | --- | --- |
| `SymphonyElixir.Codex.AppServer` | `codex/app_server.ex` | Starts and communicates with `codex app-server`. |
| `SymphonyElixir.Codex.DynamicTool` | `codex/dynamic_tool.ex` | Defines client-side dynamic tools exposed to Codex sessions. |

The important dynamic tool is `linear_graphql`, which allows repository skills to perform raw Linear
GraphQL operations from inside an agent session.

## 8. Web Observability Modules

```text
elixir/lib/symphony_elixir_web/
├── components/layouts.ex
├── controllers/
│   ├── observability_api_controller.ex
│   ├── session_controller.ex
│   ├── static_asset_controller.ex
│   └── worker_api_controller.ex
├── endpoint.ex
├── error_html.ex
├── error_json.ex
├── auth_plug.ex
├── live/admin_live.ex
├── live/dashboard_live.ex
├── live/linear_diagnostics_live.ex
├── observability_pubsub.ex
├── presenter.ex
├── router.ex
└── static_assets.ex
```

| Module | File | Responsibility |
| --- | --- | --- |
| `SymphonyElixirWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint. |
| `SymphonyElixirWeb.Router` | `router.ex` | Routes for dashboard, static assets, and JSON API. |
| `SymphonyElixirWeb.AuthPlug` | `auth_plug.ex` | Optional browser/API authentication gates. |
| `SymphonyElixirWeb.SessionController` | `controllers/session_controller.ex` | Login/logout controller. |
| `SymphonyElixirWeb.DashboardLive` | `live/dashboard_live.ex` | LiveView dashboard UI. |
| `SymphonyElixirWeb.AdminLive` | `live/admin_live.ex` | Management pages for projects, runs, workers, workflows, and settings. |
| `SymphonyElixirWeb.LinearDiagnosticsLive` | `live/linear_diagnostics_live.ex` | Linear diagnostics page. |
| `SymphonyElixirWeb.ObservabilityApiController` | `controllers/observability_api_controller.ex` | JSON API for runtime state and refresh. |
| `SymphonyElixirWeb.WorkerApiController` | `controllers/worker_api_controller.ex` | External worker registration, claim, heartbeat, and event API. |
| `SymphonyElixirWeb.StaticAssetController` | `controllers/static_asset_controller.ex` | Serves bundled static assets. |
| `SymphonyElixirWeb.Presenter` | `presenter.ex` | Converts runtime state into UI/API presentation data. |
| `SymphonyElixirWeb.ObservabilityPubSub` | `observability_pubsub.ex` | PubSub helper for dashboard state updates. |
| `SymphonyElixirWeb.StaticAssets` | `static_assets.ex` | Static asset lookup. |
| `SymphonyElixirWeb.ErrorHTML` | `error_html.ex` | HTML error responses. |
| `SymphonyElixirWeb.ErrorJSON` | `error_json.ex` | JSON error responses. |

Routes:

```text
GET  /                         LiveView dashboard
GET  /login                    Login page when auth is enabled
GET  /runs                     Run history
GET  /runs/:id                 Run detail
GET  /issues/:identifier       Persisted issue snapshot
GET  /events                   Event history
GET  /workers                  Worker, task, and lease state
GET  /settings                 Settings, defaulting to Projects
GET  /settings/projects        Project settings
GET  /settings/workflow        Workflow routing/runtime settings
GET  /settings/agents          Agent profile and prompt settings
GET  /settings/runtime         Runtime summary
GET  /diagnostics/linear       Linear diagnostics
GET  /dashboard.css             Dashboard stylesheet
GET  /api/v1/state              Full runtime state JSON
POST /api/v1/refresh            Trigger refresh
GET  /api/v1/:issue_identifier  Issue-specific state JSON
POST /api/worker/v1/register    Worker registration
POST /api/worker/v1/tasks/claim Worker task claim
POST /api/worker/v1/heartbeat   Worker heartbeat and lease renewal
POST /api/worker/v1/tasks/:id/events Worker task event reporting
```

## 9. Mix Tasks

```text
elixir/lib/mix/tasks/
├── pr_body.check.ex
├── specs.check.ex
├── symphony.build.ex
└── workspace.before_remove.ex
```

| Task | Purpose |
| --- | --- |
| `mix pr_body.check` | Checks PR body content expectations. |
| `mix specs.check` | Checks implementation/spec consistency. |
| `mix symphony.build` | Builds the escript executable used by `mix build`. |
| `mix workspace.before_remove` | Hook task intended for workspace cleanup before removal. |

## 10. Tests

```text
elixir/test/
├── mix/tasks/
├── support/
└── symphony_elixir/
```

| Path | Purpose |
| --- | --- |
| `test/symphony_elixir/core_test.exs` | Core orchestration behavior. |
| `test/symphony_elixir/workspace_and_config_test.exs` | Workspace and config behavior. |
| `test/symphony_elixir/app_server_test.exs` | Codex App Server integration behavior. |
| `test/symphony_elixir/dynamic_tool_test.exs` | Dynamic tool behavior. |
| `test/symphony_elixir/cli_test.exs` | CLI argument and startup behavior. |
| `test/symphony_elixir/orchestrator_status_test.exs` | Orchestrator status output. |
| `test/symphony_elixir/status_dashboard_log_test.exs` | Status dashboard log rendering and legacy-format regression coverage. |
| `test/symphony_elixir/auth_persistence_web_test.exs` | Authentication and persistence-backed Web UI behavior. |
| `test/symphony_elixir/observability_pubsub_test.exs` | PubSub behavior for observability updates. |
| `test/symphony_elixir/log_file_test.exs` | Log file behavior. |
| `test/symphony_elixir/persistence_provider_test.exs` | Persistence provider boundary behavior. |
| `test/symphony_elixir/web_fake_persistence_test.exs` | Web and worker API behavior through fake persistence. |
| `test/symphony_elixir/linear_diagnostics_test.exs` | Linear diagnostics behavior and route protection. |
| `test/symphony_elixir/ssh_test.exs` | SSH worker behavior. |
| `test/symphony_elixir/live_e2e_test.exs` | Live external end-to-end test with Linear and Codex. |
| `test/mix/tasks/*_test.exs` | Tests for custom Mix tasks. |
| `test/support/*` | Shared test helpers. |

## 11. Main Call Chain

The usual startup path is:

```text
bin/symphony
└── SymphonyElixir.CLI.main/1
    └── SymphonyElixir.CLI.evaluate/2
        └── Application.ensure_all_started(:symphony_elixir)
            └── SymphonyElixir.Application.start/2
                ├── SymphonyElixir.Repo
                ├── SymphonyElixir.WorkflowStore
                ├── SymphonyElixir.Orchestrator
                ├── SymphonyElixir.HttpServer
                └── SymphonyElixir.StatusDashboard
```

The usual issue execution path is:

```text
SymphonyElixir.Orchestrator
├── loads config from WorkflowStore / Config
├── fetches issues through Tracker / Linear.Adapter
├── centralized mode: prepares workspace through Workspace
├── centralized mode: renders prompt through PromptBuilder
├── centralized mode: starts agent through AgentRunner
├── centralized mode: communicates with Codex through Codex.AppServer
└── worker mode: persists run/task records for WorkerApiController claims
```

## 12. Where to Change Things

| Task | Start Here |
| --- | --- |
| Change CLI flags or startup behavior | `elixir/lib/symphony_elixir/cli.ex` |
| Change workflow parsing or reload behavior | `workflow.ex`, `workflow_store.ex` |
| Add config fields or defaults | `config.ex`, `config/schema.ex` |
| Change polling, dispatch, retry, or cleanup behavior | `orchestrator.ex` |
| Change workspace path or hook behavior | `workspace.ex`, `path_safety.ex` |
| Change prompt rendering | `prompt_builder.ex` |
| Change Linear API behavior | `linear/adapter.ex`, `linear/client.ex`, `linear/issue.ex` |
| Add another tracker | `tracker.ex`, then implement a new adapter module |
| Change Codex app-server protocol handling | `codex/app_server.ex` |
| Change dynamic tools exposed to Codex | `codex/dynamic_tool.ex` |
| Change dashboard UI | `symphony_elixir_web/live/dashboard_live.ex`, `symphony_elixir_web/live/admin_live.ex`, `presenter.ex` |
| Change JSON observability API | `symphony_elixir_web/controllers/observability_api_controller.ex` |
| Change worker API behavior | `symphony_elixir_web/controllers/worker_api_controller.ex`, `persistence.ex` |
| Change persistence schema | `persistence/*.ex`, `priv/repo/migrations/*` |
| Change auth behavior | `symphony_elixir_web/auth_plug.ex`, `controllers/session_controller.ex` |
| Change terminal status display | `status_dashboard.ex` |
| Change tests for orchestration | `test/symphony_elixir/core_test.exs` |

## 13. Development Commands

From `elixir/`:

```bash
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix test
mise exec -- make all
```

Live external end-to-end test:

```bash
export LINEAR_API_KEY=...
mise exec -- make e2e
```
