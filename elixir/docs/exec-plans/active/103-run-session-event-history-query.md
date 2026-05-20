# 103 Run Session Event History Query

## Goal

Support querying the historical session events for a specific run after the run is no longer active. Operators should be able to open or request a run by `run_id` and see the same meaningful session timeline that was visible while the agent was running, including system setup progress, Codex events, tool calls, phase boundaries, and failure context.

## Status

Active.

## Background

Running session history currently lives primarily in the orchestrator snapshot. That is useful while a run is active, but it is not enough for postmortem debugging. After a run completes, fails, retries, or the process restarts, users need to ask "what happened in this run?" and get a run-scoped session event timeline.

The database already has a generic `events` table and `Persistence.list_events(run_id: ...)`. The run detail page also lists persisted events. However, those rows are generic persisted event records, not a first-class "session history for run" query with the same presentation semantics as the live dashboard session history. This creates a gap:

- live session history is readable but ephemeral;
- persisted events are durable but too raw for the specific "show me this run's session history" workflow;
- querying by issue can mix multiple attempts/runs and obscure which attempt produced which event.

This plan adds a run-scoped history query boundary that reconstructs/presents historical session events from persisted run events.

## Scope

- Add a run-scoped historical session event query, keyed by `run_id`.
- Return events in chronological order by default so the timeline reads from run start to run finish.
- Preserve enough filtering/pagination for large runs:
  - `limit`;
  - optional cursor or before/after timestamp;
  - optional event type/source/category filters if they fit existing patterns.
- Normalize persisted records into the same display shape as live session history:
  - `at`;
  - `event`;
  - `label`;
  - `detail`;
  - `severity`;
  - `source`;
  - `phase`;
  - `operation`;
  - raw bounded metadata/payload for debugging.
- Include both system and agent events:
  - run phase boundaries;
  - workspace/worktree/git progress;
  - lifecycle hook output;
  - Codex startup/session events;
  - tool calls and tool results;
  - retries/failures where they belong to that run.
- Expose the query through a stable internal API/module rather than making LiveView pages hand-roll event transformation.
- Update the run detail page to use the run session history query or add a dedicated "Session history" section for historical runs.
- Add tests with mocked persistence/fake events; UI tests should not require a real database.
- Document how persisted historical session history relates to live in-memory session history.

## Out of Scope

- Do not rebuild old run history for events that were never persisted.
- Do not introduce a new event ingestion pipeline unless the current persisted event payloads cannot represent required fields.
- Do not change live session history coalescing behavior.
- Do not mix multiple runs when querying a single run.
- Do not make issue-level history the primary interface in this plan; issue-level aggregation can be a follow-up.
- Do not depend on real Linear, real Codex, or a real database in tests.

## Acceptance Criteria

- Given a `run_id`, Symphony can return that run's historical session events after the run is completed or failed.
- The returned timeline is ordered chronologically and bounded by the requested limit/pagination.
- The run detail page shows a readable historical session history for the selected run.
- System setup events are visibly distinct from Codex/agent events, matching the live session history source semantics.
- A run with no persisted session events shows a clear empty state, not an error.
- Querying a missing run returns a clear not-found or empty result according to the existing route/API conventions.
- Tests prove that two runs for the same issue do not leak events into each other's session history.
- Tests prove that raw persisted events are transformed into readable labels/details instead of only showing generic event type strings.
- Existing `/events` filtering remains intact.

## Test Cases

- Persistence/fake-persistence test: store events for two `run_id`s with the same issue identifier; query run A and assert only run A events are returned.
- Transformation test: a persisted `run.phase` event becomes a session-history row with system source, phase detail, severity, and timestamp.
- Transformation test: a persisted Codex/protocol event becomes a humanized agent row using existing Codex message presentation logic where possible.
- Transformation test: workspace git/hook progress events preserve `phase`, `operation`, and latest output detail.
- LiveView test: `/runs/:id` renders a "Session history" section for a historical run using fake persistence.
- LiveView test: `/runs/:id` for a run without events renders an empty state.
- Pagination/limit test: requesting a small limit returns a bounded slice without changing chronological order.
- Regression test: `/events?run_id=...` still renders the generic event table and remains independent from the session-history presentation.

## Implementation Notes

- Prefer a small module such as `SymphonyElixir.SessionHistory` or `SymphonyElixir.RunHistory` that accepts persisted `EventRecord` structs/maps and returns presentation-ready session-history entries.
- Reuse existing display logic instead of duplicating it:
  - `StatusDashboard.humanize_codex_message/1` for Codex payloads;
  - live session-history label/detail conventions where available;
  - existing source metadata from plan 095.
- Keep the persistence boundary simple:
  - `Persistence.list_events(run_id: run_id, limit: limit)` can remain the storage query;
  - add a higher-level query such as `list_run_session_events(run_id, opts)` only if it keeps LiveView/controllers cleaner.
- If persisted events currently lack the exact live `session_history` shape, map from payload metadata rather than changing every event writer in this plan.
- Be explicit about ordering. `list_events/1` currently orders descending; historical session history should either request ascending order or reverse a bounded result with clear semantics.
- Do not expose unbounded payloads in UI. Keep raw metadata bounded/scrubbed, consistent with existing event display.
- Preserve run-id filtering as the isolation boundary. Issue identifier is context, not the primary key for this query.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/*history*` if a dedicated history test file is added.
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- `mise exec -- mix format --check-formatted`
- `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Completed plan 054 for running session state history.
- Completed plan 066 for observable session-history details.
- Completed plan 067 for notification coalescing.
- Completed plan 069 for run phase boundary logs.
- Completed plan 095 for system event presentation in live session history.
- Existing persisted `events` table and `Persistence.list_events/1`.

## Handoff Notes

The product behavior is "open a run and see what happened in that run," even after the run is no longer active. Keep this separate from issue-level history because an issue can have multiple attempts. The user should not have to infer a session timeline from raw event table rows.
