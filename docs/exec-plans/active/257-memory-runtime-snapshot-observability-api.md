# 257 Memory runtime snapshot and observability API

## Goal

Keep active workflow/config reads responsive during SQLite stalls and give authenticated external
operators a bounded HTTP boundary for current issue state plus persisted run/event history.

## Status

Active.

## Background

`WorkflowStore` currently reloads SQLite on every public read and performs its one-second poll in
the reader GenServer. A stalled checkout can therefore take down config consumers and dashboards.
The observability API also treats every issue absent from the orchestrator snapshot as unknown,
which forces operators to inspect the live SQLite file directly.

The 2026-08-27 human comments extend the cache work to the authenticated HTTP status boundary and
match the current Linear description; there is no conflicting review direction.

## Scope

- Atomically publish a coherent enabled-project/default/source snapshot on an independent memory
  read path used by every `WorkflowStore` public read.
- Load SQLite once at cold start, refresh externally activated versions in one background task,
  retain last-known-good state on failure, and reject stale refresh publications by generation.
- Make explicit workflow/project mutations report success only after the complete persisted state
  has been republished.
- Add bounded Repo-backed issue, recent-run, and event projections while keeping `/api/v1/state`
  memory-only and authenticated.
- Update the owning architecture, workflow-config, observability, hot-update, operator, and
  documentation-alignment documents.

## Out of Scope

- SQLite write-contention, event-write failure, stale-run recovery, or pool-architecture changes.
- Caching persisted history/analytics/admin data or persisting ephemeral orchestrator state.
- New operator-facing cache cadence or history timeout configuration.

## Acceptance Criteria

- Four `WorkflowStore` reads perform no persistence calls and remain responsive during a blocked
  refresh; an absent owner never falls back to SQLite.
- Refresh work is single-flight, stale publications cannot beat explicit mutations, and failures
  retain one complete prior snapshot with structured errors.
- Successful workflow and project mutations expose the complete new snapshot before success is
  reported; publication failure is explicit.
- `/api/v1/state` remains persistence-free; active and inactive issue lookups and `/api/v1/runs`
  expose bounded typed success/error contracts without route shadowing or auth regressions.
- The required focused checks, exec-plan/spec checks, and full `make all` gate pass.

## Test Cases

- Instrumented and blocking workflow persistence: zero read-through calls, read responsiveness,
  single-flight polling, stale-refresh race, last-known-good error behavior, owner absence.
- Workflow import/restore and project create/update/enable-disable/delete first-read publication.
- Active issue precedence, inactive issue latest outcome, newest-first clamped history/events,
  unknown/input/Repo/query/timeout failures, route ordering, methods, and authentication.
- Concurrent blocked history with responsive workflow/orchestrator/dashboard/state reads.

## Implementation Notes

The published snapshot is replaced as one term. The cache owner coordinates refresh generations,
but no public read waits for that process. Persistence-backed HTTP history runs in a bounded task
owned by the individual request, never by runtime snapshot owners.

## Verification

- `mix lint`: passed; exec-plan index, public specs, and Credo checks are clean.
- Focused settings publication suites: 42 tests, 0 failures.
- Focused workflow-store, history, API, and auth suites: 32 tests, 0 failures.
- HTTP/runtime compatibility suite: 20 tests, 0 failures.
- `make all`: passed with 763 tests, 0 failures, 2 skipped, 85.81% coverage, and
  Dialyzer reporting zero errors.

## Completion Deviations

None.

## Dependencies

- SYM-1 merged in `origin/main` at `b3aa085`.
- Existing `PersistenceProvider`, Repo read helpers, API auth pipeline, and orchestrator snapshot.

## Handoff Notes

The required implementation branch is `vikingmew-sym-3`. History remains explicitly
persistence-backed; only active workflow/config and orchestrator current state are memory reads.
