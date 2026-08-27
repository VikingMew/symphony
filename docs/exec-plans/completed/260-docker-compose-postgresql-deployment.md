# 260 Docker Compose PostgreSQL deployment

## Goal

Provide a reproducible Docker Compose deployment for Symphony and PostgreSQL using a non-root OTP
release image that retains the runtime tools required for centralized Codex execution and SYM-1's
GitHub PR handoff.

## Status

Completed on 2026-08-27.

## Background

The root Dockerfile currently runs the dashboard from a copied source tree through Mix and stores
SQLite files in image-mode-specific volumes. There is no root Compose stack, no PostgreSQL service,
and no release-first migration/startup boundary. Plan 259 establishes PostgreSQL as the sole
runtime backend and is the required foundation for this deployment.

## Scope

- Adapt the existing root Dockerfile to build a real Elixir 1.19/OTP 28 release; do not add a
  second image path.
- Keep the final Symphony image non-root, with no Mix, compiler, or checked-out source tree, while
  including Codex CLI, `gh`, git, SSH client, ripgrep, certificates, shell/runtime support, and
  PostgreSQL client tools needed by documented operations.
- Add root `compose.yaml` with Symphony and PostgreSQL services, named database/log/workspace and
  credential volumes, internal networking, restart policies, healthchecks, dependency ordering,
  and configurable dashboard port.
- Run migrations after PostgreSQL readiness and before the application serves work. Use
  PostgreSQL readiness and Symphony `/health/ready` as health gates.
- Provide a credential-free environment template/reference covering application `DATABASE_URL`,
  Compose `POSTGRES_*`, Linear, Codex/OpenAI, GitHub, auth, proxy, and runtime settings.
- Document build, first start, explicit migrations, health/status, logs, stop/start, upgrades,
  volume persistence, restart recovery, `pg_dump`/restore, SQLite cutover, verification, rollback,
  container-visible paths, and credential mounts.
- Retain the direct local CLI development path and current reverse-proxy/Kubernetes guidance. Add
  no launchd machinery.

## Out of Scope

- A second Dockerfile, image registry publishing, Helm charts, or managed PostgreSQL provisioning.
- Public TLS/domain ownership, PgBouncer, read replicas, multi-node scheduling, or leader election.
- A standalone worker-client redesign or alternate execution protocol.

## Acceptance Criteria

1. `docker compose config` succeeds with the documented environment contract and no committed
   credentials.
2. `docker compose build` produces a non-root OTP release image with no Mix/compiler/source tree;
   `codex`, `gh`, git, SSH, and ripgrep are executable in the final image.
3. `docker compose up -d` starts PostgreSQL, waits for healthy readiness, applies migrations, then
   starts Symphony and reaches healthy `/health/live` and `/health/ready` endpoints.
4. PostgreSQL data plus Symphony logs/workspaces and documented credential state survive service
   recreation through named volumes; PostgreSQL is not published to the host by default.
5. Restart policies recover killed services without resetting database state, and Symphony
   restarts without SQLite lock-induced stale-run behavior.
6. Application and child Codex/`gh` processes receive the documented credentials/config at runtime
   without embedding secrets in the image or repository.
7. The operator guide contains tested backup/restore and SQLite cutover commands plus verification
   and rollback steps.
8. Existing reverse-proxy/Kubernetes guidance links to the Compose and cutover sources of truth,
   and local CLI development remains documented.

## Test Cases

- Render Compose configuration with example-safe values and scan it/repository files for embedded
  credentials.
- Inspect the built image user, filesystem, release boot, and required tool versions.
- Observe PostgreSQL healthy before the migration job completes and Symphony starts.
- Probe both health endpoints after startup.
- Create durable database/application evidence, recreate containers, and verify it remains.
- Kill/restart each long-running service and verify health plus retained state.
- Run documented `pg_dump`, restore into an empty target, and compare application table counts.

## Implementation Notes

- Use a release command or eval boundary for migrations; normal application boot must not race
  migrations.
- One `DATABASE_URL` connects Symphony to Compose PostgreSQL. `POSTGRES_*` configures only the
  PostgreSQL container.
- Keep PostgreSQL on the internal Compose network with no host port mapping by default.
- Mount operator Codex/GitHub state or pass environment tokens explicitly; do not copy host
  credentials into an image layer.

## Verification

- `docker compose --env-file .env.example config --quiet` passed, and the credential-pattern scan
  found no committed API tokens. The example contains only explicit `change-me` placeholders.
- `docker compose --env-file .env.example build` produced the root Dockerfile's OTP release image.
  Runtime inspection reported UID/GID 10001, Codex CLI 0.150.1, gh 2.46.0, git 2.47.3,
  OpenSSH 10.0, ripgrep 14.1.1, PostgreSQL client 17.11, and SQLite 3.46.1. Mix, `elixirc`, gcc,
  make, `mix.exs`, config/test source, and `.git` were absent from the final image.
- `docker compose up -d` observed PostgreSQL healthy, the migration job exiting 0, then Symphony
  healthy. `/health/live` returned `status=ok`; `/health/ready` returned `status=ready` with
  database/web checks `ok` and the expected non-blocking workflow `setup_required` state.
- A PostgreSQL settings row plus log/workspace marker files survived forced container recreation.
  Both long-running service PID 1 processes were killed and recovered through `unless-stopped`;
  Symphony returned ready, reconnected to PostgreSQL, and retained the database marker.
- A custom-format `pg_dump` of the Compose database restored into an isolated empty database.
  Counts matched for all 14 application tables; the restore database and temporary dump were
  removed after verification.
- The final rebuilt image was started again after all dependency/code changes; migration exited 0,
  both services were healthy, and every persistence-volume probe remained present.

## Completion Deviations

None.

## Dependencies

- Completed plan 259 PostgreSQL runtime and SQLite cutover.
- SYM-1 runtime `gh` behavior and centralized execution tooling.

## Handoff Notes

The Compose stack is the supported self-hosted deployment path. The local `bin/symphony` command
remains the development path and uses the same PostgreSQL connection contract.
