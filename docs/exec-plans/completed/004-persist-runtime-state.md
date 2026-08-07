# Task 004: Persist Runtime State

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 002, Task 003 recommended
**Created**: 2026-05-01

## Goal

Persist issue, run, workspace, agent turn, and event state to SQLite so dashboard history and debugging survive process restarts.

## Background

The current runtime status is primarily in memory and logs. That is enough for live observation but weak for long-running operations, failure analysis, and future UI pages.

Persisting runtime state gives Symphony a durable operational timeline:

- which issues were discovered
- which workflow version was used
- when a run started or failed
- what workspace path was assigned
- which Codex turns ran
- why retries were scheduled

## Scope

- Add persistence models for:
  - `issues`
  - `runs`
  - `agent_turns`
  - `workspaces`
  - `events`
- Persist important orchestrator lifecycle events.
- Attach each run to a workflow version when available.
- Persist workspace path and cleanup status.
- Persist current run status and terminal outcome.
- Make dashboard/API capable of reading persisted state where useful.
- Add tests for state writes during orchestrator lifecycle.

## Out of Scope

- Full log streaming storage.
- Storing complete Codex transcripts.
- Reconstructing active in-flight BEAM processes after restart.
- Web UI redesign. That belongs to Task 007.

## Acceptance Criteria

- [ ] Discovered issues are recorded or updated in SQLite.
- [ ] Each dispatched run creates a `runs` record.
- [ ] Run status changes are persisted.
- [ ] Agent turn start/finish events are persisted.
- [ ] Workspace creation and cleanup status are persisted.
- [ ] Retry, failure, stop, and completion events are persisted.
- [ ] Dashboard/API can show historical runs after service restart.
- [ ] Tests cover normal completion, failure, retry scheduling, and terminal cleanup persistence.

## Test Cases

- Polling a candidate issue upserts an issue snapshot.
- Dispatching an issue creates a run tied to project and workflow version.
- Normal run completion updates run status and finished timestamp.
- Agent turn start and finish create/update `agent_turns` records.
- Workspace creation records path and created status.
- Terminal cleanup records cleanup status and cleanup event.
- Failed run records failure reason and failure event.
- Retry scheduling records next retry/backoff event.
- Stopping an ineligible active issue records stop event and terminal run status.
- Restarting the application leaves historical runs queryable from SQLite.
- Dashboard/API history endpoint or presenter can read persisted records.

## Implementation Notes

- Keep persistence append-friendly with an `events` table.
- Use idempotent upserts for issue snapshots.
- Do not block orchestrator progress on non-critical presentation writes where avoidable, but do fail clearly on core DB setup problems.
- Add stable event type names now; future UI pages will depend on them.
- Keep payloads structured JSON where the schema may evolve.

## Verification

- Focused tests for orchestrator lifecycle persistence.
- Focused tests for dashboard/API reading persisted history.
- `mise exec -- mix test test/symphony_elixir/core_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test`
- Manual check: start service, trigger refresh, restart service, verify prior run/history remains visible.

## Completion Deviations

- Runtime persistence records issue snapshots, runs, workspaces, Codex updates, and events for the default production orchestrator.
- Test-only named orchestrators do not write runtime persistence to avoid changing timing-sensitive scheduling tests.
- Full Codex transcript persistence remains out of scope; event payloads store compact structured summaries.

## Handoff Notes

- Record the event type names introduced.
- Record what state is persisted synchronously vs asynchronously.
- Record which runtime state still remains memory-only.
