---
title: Trusted HTTP Execution Worker Operations
genre: guide
domain: [worker, deployment, operations]
status: current
language: en
updated: 2026-08-29
owner: compose.yaml
---

# Trusted HTTP Execution Worker Operations

This L5 guide operates the opt-in Compose service named `execution-worker`. It is the trusted
worker-v1 HTTP runtime, not the Dockerfile `worker` target used for centralized SSH execution.
`centralized` remains the default. Enabling the profile alone does not route work; routing changes
only when `SYMPHONY_EXECUTION_MODE=worker` is applied to a newly started Panel.
For each claim, the worker launches `codex app-server`, drives one JSON-RPC turn over stdio, and
stops the session before running required gates and handoff commands.

Execution ownership is deliberately exclusive. The default centralized Panel combines control
with local execution, so its image contains Codex and its service mounts `codex_home`. The
published worker-mode Panel is pure control: it is built with `SYMPHONY_EMBED_CODEX=false`, has no
Node/Codex runtime or `CODEX_HOME`, and does not mount Codex credentials. The `execution-worker`
image always contains Codex and stores its OAuth state only in `execution_worker_codex`.

## Preflight and credentials

Copy `.env.example` to the ignored `.env`. Base Compose defaults to the checked-in exact local image
tag and source revision and builds from the checkout. Published Compose removes that build and
requires an immutable `ghcr.io/vikingmew/symphony-execution-worker` SHA tag or digest. Select it
from the same publication as `SYMPHONY_IMAGE` and set its full commit in
`SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION`.
Give the worker only these credentials: the Panel registration token, a least-scope Codex token,
a repository push/PR token, and the existing `LINEAR_API_KEY` credential. Never set
`DATABASE_URL` or `POSTGRES_*` on `execution-worker`.

Provide the repository token as `GH_TOKEN` or `GITHUB_TOKEN` with clone and push permission for the
configured repository. The image's `/etc/gitconfig` rewrites the exact GitHub SCP-style prefix to
HTTPS and delegates credentials to `gh`; do not inject `GIT_CONFIG_*`, GitHub `known_hosts`, or SSH
host-key policy for that URL form. Other hosts and SSH URL forms retain their normal SSH semantics.

The worker joins `worker_control` to reach only `http://symphony:4000/api/worker/v1/*`; it does not
join the database network. Its `worker_egress` network must be restricted by the deployment
firewall or the configured HTTP proxy to Codex, the configured Git/PR host, Linear, Hex, npm,
Debian and GitHub release registries required to build this repository.
Set `SYMPHONY_EXECUTION_WORKER_NO_PROXY` only to the Panel service and loopback names. Treat an
unrestricted `worker_egress` network as a failed production preflight.

Validate without printing substituted secrets:

```bash
grep -Eq '^SYMPHONY_WORKER_REGISTRATION_TOKEN=.+$' .env
docker compose --env-file .env --profile execution-worker config --quiet
docker compose --env-file .env --profile execution-worker build execution-worker
docker compose --env-file .env run --rm --no-deps --entrypoint sh execution-worker -lc '
  test "$(id -u)" = 10002 &&
  test "$SYMPHONY_ROLE" = worker &&
  test -z "$DATABASE_URL" && test -n "$LINEAR_API_KEY" &&
  command -v codex && command -v gh && command -v git && command -v make && command -v mise &&
  command -v mix && command -v elixir && command -v erl &&
  mise --version && mise exec -- mix --version
'
```

The image installs mise `2025.8.16` and links its preinstalled Erlang `28` and Elixir
`1.19.5-otp-28` runtimes at build time. Runtime setup never downloads a language toolchain.
`MIX_HOME`, `HEX_HOME`, `MISE_CACHE_DIR`, and `XDG_CACHE_HOME` all point into the writable
`/worker/cache` volume;
project build output remains in the writable `/worker/workspaces` volume while the root filesystem
stays read-only. The `/tmp` tmpfs permits execution for native libraries and test helpers created
by project quality gates. External publication CI owns the non-root image smoke and an in-image
`make all`; Symphony implementation agents only run static configuration/source validation.

The explicit token check keeps the base Compose model valid for centralized-only deployments while
failing the worker preflight before container startup when its registration credential is absent.

Inspect the image ID/digest locally with `docker image inspect --format '{{.Id}} {{index
.RepoDigests 0}}' "$SYMPHONY_EXECUTION_WORKER_IMAGE"`; record identifiers, never the full
environment or rendered Compose output.

## Deploy, rotate, and inspect

For a published deployment, include both Compose files and matching immutable Panel and worker
references. The override selects worker execution for the Codex-free Panel; the execution-worker
profile remains opt-in and must be started with it:

```bash
docker compose -f compose.yaml -f compose.published.yaml --env-file .env up -d postgres migrate symphony
docker compose -f compose.yaml -f compose.published.yaml --env-file .env --profile execution-worker up -d execution-worker
```

Start the Panel in its existing `centralized` mode, then opt in the idle worker:

```bash
docker compose --env-file .env up -d postgres migrate symphony
docker compose --env-file .env --profile execution-worker up -d execution-worker
docker compose --env-file .env ps
curl --fail http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT:-4000}/health/ready
```

Open `/workers` and retain the worker/session ID, protocol/runtime identity, heartbeat time, and
available slots. A healthy idle worker has no claim until new work is routed to worker mode. To
rotate a credential, stop the worker, replace only that value in `.env`, revoke the old token at
its issuer, and recreate the service. Rotating the shared registration token also requires
recreating the Panel.

## End-to-end verification record

Use a real Symphony issue for this repository. Route only new work by setting
`SYMPHONY_EXECUTION_MODE=worker` and recreating the Panel; then dispatch the issue normally. Retain
this redacted record from `/workers`, `/runs/<id>`, Git, the PR host, and Linear:

```text
date; project_id; issue identifier/stable ID; run_id/run_attempt
task_id; lease_id/lease_attempt; worker/session; image digest; worker source revision
resolved source revision; ordered gate: make all / status / exit / duration
branch; commit; PR; allowed Linear transition; terminal event/time
workspace cleanup or quarantine result; external-write idempotency result
```

Success requires `make all` to pass inside the worker before the structured `handoff` writeback, one terminal completion, the
expected branch/commit/PR and allowed Linear update, and removal of the successful lease workspace.
Do not retain credentials, Compose output, prompts, or raw logs. Redact URLs containing user info,
headers, tokens, repository credentials, prompt text, and local file contents; keep only bounded
error summaries and identifiers.

## Cancellation drill

Start a task with a deliberately long non-handoff phase and use **Cancel** for its active task on
`/workers`. Record cancellation observation time, last phase, terminal state, grace-period timing,
descendant-reaping result, and cleanup/quarantine path status. Verify no later phase event appears,
the lease process group and descendants stop within the configured command grace period, the task
is cancelled/reconciled, and no PR or Linear handoff is newly performed. Inspect only metadata:

```bash
docker compose --env-file .env exec execution-worker sh -lc '
  find /worker/workspaces /worker/logs -mindepth 1 -maxdepth 4 -printf "%y %p\n"
'
```

## Crash, expiry, and duplicate drill

During an active task, force a worker loss with `docker compose --env-file .env kill
execution-worker`. Wait for the lease to expire in `/workers`, then recreate the worker. Requeue
the expired task from `/workers` if policy does not do so automatically. Record that the replacement
claim has the same task and run attempt, a new lease ID, and lease attempt incremented by one.

After recovery completes, replay the old lease's saved terminal request and the current terminal
request through the worker-v1 endpoint using a scrubbed test client. Both must be rejected or
idempotent: the old lease cannot mutate the current result, the current task has one terminal
transition, and the existing branch/commit/PR/Linear references are reported rather than created
again. Retain HTTP status/error codes and persisted event IDs, not request authorization or bodies.

## Cleanup and rollback

Successful workspaces disappear after reporting. Failed/cancelled work is quarantined under the
separate workspace/log volumes until `SYMPHONY_EXECUTION_WORKER_RETENTION_SECONDS`; cache eviction
uses its separate byte and age limits. Investigate escapes, secrets, orphan descendants, skipped
validation, repeated lease loss, capacity loss, or divergent handoff as rollback triggers.

Rollback affects new work only and preserves PostgreSQL runs, tasks, leases, sessions, and events:

For a published rollback, first select a previously recorded matching pair of image references and
set `SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION` to that worker image's full commit. Add
`-f compose.yaml -f compose.published.yaml` to the commands below.

```bash
docker compose --env-file .env --profile execution-worker stop execution-worker
# set SYMPHONY_EXECUTION_MODE=centralized in .env
docker compose --env-file .env up -d --force-recreate symphony
docker compose --env-file .env ps
```

Verify the worker has no new heartbeat/claim, the Panel is ready, existing history remains visible,
and a newly dispatched disposable task uses centralized execution. Named worker volumes are
preserved; do not use `docker compose down -v`.

## Default-mode decision — 2026-08-28

Retain `centralized` as the default and keep the HTTP worker opt-in. The checked-in deployment and
automated contracts are necessary but are not operational evidence: this repository has not yet
recorded the credentialed success, cancellation, lease-expiry recovery, duplicate-delivery, and
rollback drills described above. Switching the default before those gates pass would risk stalled
work or divergent handoff. A later decision may route only new work to `worker` after one redacted
record demonstrates every gate; centralized rollback remains required.
The Panel periodically expires stale worker sessions and leases. A worker keeps a completed lease in
its heartbeat while retrying terminal delivery; if its bounded delivery attempts are exhausted, lease
renewal stops and the Panel requeues the task after expiry. Late events from the old lease remain
fenced by the active-lease check.
