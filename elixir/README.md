# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

## Fork Status

This Elixir implementation has diverged from the upstream OpenAI Symphony preview. This fork keeps
the original orchestration model, but now runs as a Phoenix-backed control plane with local SQLite
persistence, optional username/password authentication, workflow version storage, Linear
diagnostics, worker/task management pages, and a versioned HTTP API for external workers.

Use this README together with:

- [docs/user_guide.zh-CN.md](docs/user_guide.zh-CN.md): user installation and startup guide.
- [docs/persistence_and_auth.md](docs/persistence_and_auth.md): SQLite/auth configuration.
- [docs/long_term_direction.zh-CN.md](docs/long_term_direction.zh-CN.md): long-term direction and technical choices.
- [docs/exec-plans/README.md](docs/exec-plans/README.md): completed implementation plans.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

This fork also persists local operational data in SQLite, can protect the Web UI/API with optional
username/password authentication, stores complete workflow versions, and exposes Panel-side worker
control-plane APIs. Centralized in-process execution remains the default. When
`SYMPHONY_EXECUTION_MODE=worker`, the orchestrator queues tasks for external workers through the
worker HTTP API instead of starting Codex locally.

During app-server sessions, Symphony serves restricted client-side Linear task tools:
`linear_task_read` and `linear_task_update`. Codex can read the current task, comments, and request
policy-checked task updates without receiving Linear API credentials or raw GraphQL access.

If a claimed issue moves to a terminal state (`Done`, `Canceled`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

The default Linear workflow is gated by human review between agent phases:

```text
Backlog -> Refining -> Needs Refinement Review -> Ready -> In Progress
  -> Needs Implementation Review -> Ready to Merge -> Merging -> Done
```

Only the agent-work states are configured as active states: `Refining`, `Ready`, `In Progress`,
`Ready to Merge`, and `Merging`. Human review states are intentionally inactive so Symphony stops
until a person moves the issue forward.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's restricted `linear_task_read` and `linear_task_update`
     app-server tools.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on a gated Linear state flow:
     "Refining", "Needs Refinement Review", "Ready", "In Progress", "Needs Implementation Review",
     "Ready to Merge", "Merging", "Done", "Canceled", and "Duplicate". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix ecto.migrate
mise exec -- mix build
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

Open the dashboard at `http://127.0.0.1:4000/`.

### Docker Images

The Dockerfile exposes four targets from the `elixir/` directory.

Builds can use internal registries and mirrors through build args:

```bash
docker build --target all-in-one -t symphony-all-in-one \
  --build-arg ELIXIR_IMAGE="registry.example.com/library/elixir:1.19-otp-28-slim" \
  --build-arg NODE_IMAGE="registry.example.com/library/node:20-bookworm-slim" \
  --build-arg APT_DEBIAN_MIRROR="https://apt-mirror.example.com/debian" \
  --build-arg APT_SECURITY_MIRROR="https://apt-mirror.example.com/debian-security" \
  --build-arg NPM_REGISTRY="https://npm.example.com" \
  --build-arg HEX_MIRROR_URL="https://hex.example.com" \
  .
```

Docker's standard `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` build args can also be passed when
the build environment reaches public sources through an internal proxy.

Runtime proxy settings are separate from build-time mirrors. At startup, Symphony reads standard
proxy environment variables for its own HTTP calls and passes the same variables to launched
`codex app-server` child processes:

- `HTTP_PROXY` / `http_proxy`
- `HTTPS_PROXY` / `https_proxy`
- `ALL_PROXY` / `all_proxy`
- `NO_PROXY` / `no_proxy`

Pass them with `-e` when the running container needs a proxy:

```bash
docker run --rm -it \
  -p 4000:4000 \
  -v symphony-data:/data \
  -v "$HOME/.codex:/home/symphony/.codex" \
  -e LINEAR_API_KEY="$LINEAR_API_KEY" \
  -e HTTPS_PROXY="http://proxy.example.com:8080" \
  -e NO_PROXY="127.0.0.1,localhost" \
  symphony-all-in-one
```

For SSH worker deployments, set the proxy variables inside the worker container as well; Symphony
also exports its runtime proxy variables in the remote `codex app-server` launch command.

All-in-one runs the Phoenix dashboard, internal SQLite persistence, local workspace execution, and
the Codex CLI in one container:

```bash
docker build --target all-in-one -t symphony-all-in-one .

docker run --rm -it \
  -p 4000:4000 \
  -v symphony-data:/data \
  -v "$HOME/.codex:/home/symphony/.codex" \
  -e LINEAR_API_KEY="$LINEAR_API_KEY" \
  symphony-all-in-one
```

Dashboard with internal DB runs the Panel, worker API, and SQLite in `/data`. It defaults to
`SYMPHONY_EXECUTION_MODE=worker`, so agents are expected to run outside the dashboard container:

```bash
docker build --target dashboard-internal-db -t symphony-dashboard .

docker run --rm -it \
  -p 4000:4000 \
  -v symphony-data:/data \
  -e LINEAR_API_KEY="$LINEAR_API_KEY" \
  -e SYMPHONY_WORKER_REGISTRATION_TOKEN="replace-this-worker-token" \
  symphony-dashboard
```

Dashboard with external DB uses an externally mounted SQLite path at `/external/symphony.db`.
Network databases such as PostgreSQL or MySQL are not supported by the current Ecto adapter:

```bash
docker build --target dashboard-external-db -t symphony-dashboard-external-db .

docker run --rm -it \
  -p 4000:4000 \
  -v "$PWD/.symphony-db:/external" \
  -v symphony-data:/data \
  -e LINEAR_API_KEY="$LINEAR_API_KEY" \
  -e SYMPHONY_WORKER_REGISTRATION_TOKEN="replace-this-worker-token" \
  symphony-dashboard-external-db
```

Worker builds an SSH-reachable Codex worker image for centralized mode with `worker.ssh_hosts`.
Mount SSH authorized keys and Codex auth into the worker container:

```bash
docker build --target worker -t symphony-worker .

docker run --rm -it \
  -p 2222:22 \
  -v "$HOME/.ssh/authorized_keys:/home/symphony/.ssh/authorized_keys:ro" \
  -v "$HOME/.codex:/home/symphony/.codex" \
  symphony-worker
```

All dashboard images start in dashboard-first `--port` mode, run `mix ecto.migrate` on startup,
write logs under `/data/logs`, and expose the dashboard at `http://127.0.0.1:4000/`.

For dashboard-first setup with SQLite, `WORKFLOW.md` is optional when you start with `--port` and
do not pass an explicit workflow path:

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000
```

If an active workflow version already exists in SQLite, Symphony loads it. If the database is empty,
open `/workflows` and create the first workflow from the raw editor. Traditional non-port CLI runs
still require `WORKFLOW.md` unless database workflow loading is explicitly configured.

Execution mode defaults to centralized in-process execution:

```bash
export SYMPHONY_EXECUTION_MODE=centralized
```

Centralized mode can run locally, or it can use SSH hosts listed in `worker.ssh_hosts` to launch
workspace hooks and `codex app-server` remotely over SSH.

Worker mode queues tasks for external workers:

```bash
export SYMPHONY_EXECUTION_MODE=worker
```

The worker API requires a registration token:

```bash
export SYMPHONY_WORKER_REGISTRATION_TOKEN="replace-this-worker-token"
```

Optional local authentication:

```bash
export SYMPHONY_AUTH_ENABLED=true
export SYMPHONY_ADMIN_USERNAME=admin
export SYMPHONY_ADMIN_PASSWORD="replace-this-password"
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md` for non-port CLI runs. In `--port`
dashboard mode, Symphony uses SQLite as the runtime workflow source. `WORKFLOW.md` is only an
initial seed when no active database workflow exists; after that, `/workflows` edits the active
database workflow used by the dashboard and Linear diagnostics.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled) and enables
  database-backed workflow loading for dashboard-first setup

SQLite configuration:

- `SYMPHONY_DATABASE_PATH` sets the local SQLite file path (default: `elixir/symphony.db`)
- Run `mise exec -- mix ecto.migrate` before first use

Authentication configuration:

- `SYMPHONY_AUTH_ENABLED=true` enables login protection
- `SYMPHONY_ADMIN_USERNAME` sets the admin username
- `SYMPHONY_ADMIN_PASSWORD` or `SYMPHONY_ADMIN_PASSWORD_HASH` sets the password credential

The `WORKFLOW.md` file is the import/export artifact for one workflow package. Its YAML front
matter contains runtime configuration, a `workflow` object for state routing and transitions, and
top-level `profiles` for execution definitions. The Markdown body is the base Codex session prompt.
Each profile may add a profile prompt policy:

- `extend` uses the profile prompt together with the base prompt, rendered as profile template first and base prompt second.
- `replace` uses the profile prompt template instead of the base prompt.
- `disabled` is valid for non-Codex executors and leaves no profile prompt for Codex.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
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

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `agent.max_concurrent_agents_by_state` can override concurrency limits per normalized issue
  state; state names are case-insensitive after normalization.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- `hooks.before_run`, `hooks.after_run`, and `hooks.before_remove` are also supported. Hook timeout
  is controlled by `hooks.timeout_ms` and defaults to `60000`.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.assignee` reads from `LINEAR_ASSIGNEE` when unset or when value is `$LINEAR_ASSIGNEE`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- In explicit file mode, a missing or invalid startup `WORKFLOW.md` prevents boot.
- In dashboard-first `--port` mode without an explicit workflow path, Symphony starts from the
  active SQLite workflow version. If no active version exists, it imports local `WORKFLOW.md` once
  when present; otherwise the dashboard starts in setup-required mode so `/workflows` can create
  the first workflow.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the source is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability and management UI runs on a Phoenix stack:

- LiveView for the dashboard at `/`
- LiveView management pages at `/projects`, `/runs`, `/workers`, `/workflows`, and `/settings`
- Linear integration diagnostics at `/diagnostics/linear`
- JSON API for operational debugging under `/api/v1/*`
- Worker API under `/api/worker/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
