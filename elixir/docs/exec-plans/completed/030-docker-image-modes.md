# Task 030: Docker Image Modes

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 017, 018, 026, 029
**Created**: 2026-05-06
**Completed**: 2026-05-06

## Goal

Provide Docker build targets for the common Symphony deployment shapes:

- all-in-one;
- dashboard with internal database;
- dashboard with external database path;
- worker.

These images should make local and containerized deployment easier without changing Symphony's runtime model.

## Background

Symphony currently runs as an Elixir/Phoenix control plane with SQLite persistence and Codex execution. Dashboard-first `--port` mode allows the Web UI to create and manage workflow versions from SQLite. Centralized execution runs Codex locally or through SSH hosts. Worker mode queues tasks through the worker API, but the repository does not yet include a standalone HTTP worker client process.

The project had only a test support Dockerfile for live E2E workers. It needed production-facing image targets for operators to run the dashboard, persist state, and prepare Codex-capable worker environments.

## Scope

- Add a root `elixir/Dockerfile` with these targets:
  - `all-in-one`;
  - `dashboard-internal-db`;
  - `dashboard-external-db`;
  - `worker`.
- Add a root `elixir/.dockerignore` to keep local build artifacts, dependencies, coverage output, logs, SQLite files, tests, and docs out of the image build context.
- Expose build arguments for internal image registries, package mirrors, and proxy-based builds.
- Keep dashboard images in dashboard-first `--port` mode.
- Run `mix ecto.migrate` at container startup before launching Symphony.
- Store default dashboard SQLite state at `/data/symphony.db`.
- Store dashboard logs under `/data/logs`.
- Include Codex CLI, Node, git, SSH client, ripgrep, and SQLite tools in the all-in-one image.
- Keep dashboard-only images lighter by excluding Codex CLI from the final runtime.
- Add an SSH worker image that includes Codex CLI, git, ripgrep, Python, and OpenSSH server.
- Update README with build and run examples for all four targets.

## Out of Scope

- Adding PostgreSQL, MySQL, or other network database adapters.
- Implementing a standalone HTTP worker client process.
- Adding Docker Compose orchestration for dashboard plus workers.
- Adding container registry publishing.
- Adding image signing or SBOM generation.
- Maintaining organization-specific registry credentials or mirror certificates in this repository.
- Replacing the current Mix wrapper with a release artifact.
- Changing runtime persistence schemas.
- Changing Linear workflow states or orchestration behavior.

## Acceptance Criteria

- [x] `docker build --target all-in-one -t symphony-all-in-one .` is documented.
- [x] `docker build --target dashboard-internal-db -t symphony-dashboard .` is documented.
- [x] `docker build --target dashboard-external-db -t symphony-dashboard-external-db .` is documented.
- [x] `docker build --target worker -t symphony-worker .` is documented.
- [x] All dashboard images expose port `4000`.
- [x] All dashboard images use the guardrails acknowledgement flag automatically.
- [x] All dashboard images run `mix ecto.migrate` before service start.
- [x] `all-in-one` includes Codex CLI and mounts `/home/symphony/.codex`.
- [x] `dashboard-internal-db` defaults to `/data/symphony.db`.
- [x] `dashboard-external-db` defaults to `/external/symphony.db`.
- [x] `worker` exposes SSH on port `22` and can mount authorized keys and Codex auth.
- [x] README explains that external DB currently means an externally mounted SQLite path, not a network DB.
- [x] Docker builds can override `ELIXIR_IMAGE`, `NODE_IMAGE`, apt mirrors, npm registry, and Hex mirror.
- [x] README documents mirror/proxy build args.

## Test Cases

- Static-check Dockerfile syntax and target names by inspection.
- Verify `.dockerignore` excludes local `_build`, `deps`, `cover`, logs, SQLite files, tests, docs, and generated wrapper output.
- Verify README examples reference the correct Docker targets and volume paths.
- Verify README explains how to override public registries and package sources.
- Attempt a Docker build from the `elixir/` context.
- Keep existing Elixir tests and coverage green after Docker and docs changes.

## Implementation Notes

- The Dockerfile uses a Codex stage based on `node:20-bookworm-slim`, then copies `node`, `npm`, `npx`, `codex`, and global node modules into targets that need Codex.
- The build stage uses `elixir:1.19-otp-28-slim`, compiles prod dependencies, compiles the app, and runs `mix build` to generate `bin/symphony`.
- `ELIXIR_IMAGE` and `NODE_IMAGE` can point at internal registry mirrors.
- `APT_DEBIAN_MIRROR` and `APT_SECURITY_MIRROR` can replace Debian package sources during build.
- `NPM_REGISTRY` can point Codex CLI installation at an internal npm registry or proxy.
- `HEX_MIRROR_URL` configures Hex after `mix local.hex` has installed Hex.
- Docker's standard `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` build args can be passed without custom Dockerfile handling.
- `app-runtime` is the shared dashboard runtime base. It defaults to `SYMPHONY_EXECUTION_MODE=worker`, so dashboard-only targets do not start local Codex sessions.
- `all-in-one` inherits from `app-runtime` but sets `SYMPHONY_EXECUTION_MODE=centralized` and adds Codex CLI.
- `dashboard-external-db` uses SQLite at `/external/symphony.db`. This is the most honest currently supported external database model because the code is configured for `Ecto.Adapters.SQLite3`.
- The worker target is an SSH worker image for centralized mode with `worker.ssh_hosts`. It is not an HTTP worker API client.
- The worker SSH server sets `StrictModes no` so bind-mounted `authorized_keys` can be accepted in local Docker runs without requiring exact host-side ownership.

## Verification

- [x] `git diff --check`
- [ ] `docker build --target all-in-one -t symphony-all-in-one:local elixir`
- [ ] `docker build --target dashboard-internal-db -t symphony-dashboard:local elixir`
- [ ] `docker build --target dashboard-external-db -t symphony-dashboard-external-db:local elixir`
- [ ] `docker build --target worker -t symphony-worker:local elixir`

## Completion Deviations

Docker build verification could not complete in this environment. Docker daemon access was approved, but the build failed while pulling Docker Hub base images because `registry-1.docker.io` timed out.

The requested "dashboard with external db" target was implemented as an externally mounted SQLite database path. PostgreSQL/MySQL-style external database support is not currently present in the codebase and would require additional dependencies, runtime configuration, migrations, and deployment documentation.

The requested "worker" target was implemented as an SSH worker image because the codebase currently supports remote Codex execution through `worker.ssh_hosts`. A standalone worker API polling process is not present yet.

## Dependencies

- Task 017 port-mode database workflow bootstrap, because dashboard images start in `--port` mode.
- Task 018 workflow UI create-from-empty database, because dashboard-first setup depends on `/workflows`.
- Task 026 fake persistence boundary, because tests intentionally avoid Repo by default even though runtime images start Repo.
- Task 029 Linear workflow state model, because Dockerized dashboard setup presents the new workflow defaults.

## Handoff Notes

- Build from `elixir/`, not the repository root, unless the build context path is passed explicitly.
- Pass registry and mirror build args in CI instead of editing the Dockerfile for each environment.
- Use `all-in-one` for a single-container local trial with local Codex execution.
- Use `dashboard-internal-db` when the dashboard owns its SQLite volume and workers are outside the container.
- Use `dashboard-external-db` when SQLite is mounted from a host-managed directory.
- Use `worker` with a `worker.ssh_hosts` entry such as `symphony@host:2222`.
- Add real network DB support before documenting PostgreSQL/MySQL as external DB options.
- Add a standalone HTTP worker runtime before presenting the worker image as a worker API client.
