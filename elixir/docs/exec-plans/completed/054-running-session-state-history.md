# 054 Running Session State History

## Goal

Show the full state history for a running session, not only the current session state.

An operator should be able to open one active session on the dashboard and see the chronological lifecycle of that run: queued, workspace prepared, agent starting, Codex session started, turn events, retries, failures, cancellations, and terminal completion.

## Status

Completed.

## Background

The dashboard currently emphasizes the latest view of active work: one running entry per issue with current workspace, current session id, last Codex event, elapsed time, and retry state. That is useful for a snapshot, but it hides the path that produced the current state.

For debugging real runs, the current state is often not enough. A run can be waiting because of a workspace hook, Codex startup, a retry backoff, a Linear transition request, or a failed turn. Operators need the sequence of state changes for the specific running session they are looking at.

This is session history inside Symphony, not Linear issue state history. Linear remains the source of issue workflow state; Symphony should expose its own run/session lifecycle events.

## Scope

- Define a canonical state-event model for running sessions.
- Record append-only session state events for important lifecycle transitions:
  - run queued;
  - run started;
  - workspace creation started/succeeded/failed;
  - agent process dispatched;
  - Codex app-server startup started/succeeded/failed;
  - Codex session started;
  - Codex turn started/progress/completed/failed;
  - retry scheduled;
  - cancellation requested/observed;
  - run completed/failed/stopped.
- Attach each event to a stable run/session identity:
  - `run_id` when persistence is enabled;
  - issue id / issue identifier;
  - worker host;
  - workspace path when known;
  - Codex session id when known.
- Preserve the current latest-state dashboard summary.
- Add a way on the dashboard to expand a running session and view its ordered history.
- Persist events through the existing persistence boundary when database persistence is enabled.
- Keep an in-memory fallback for current-runtime sessions when persistence is disabled or unavailable.
- Make event payloads bounded and scrubbed so they are safe to display.

## Out of Scope

- Showing full Linear issue workflow transition history.
- Adding raw Codex JSON-RPC transcript viewing.
- Adding a general-purpose log viewer for all application logs.
- Building search, filters, or retention controls for historical events.
- Changing retry policy or workflow state transitions.
- Changing the worker API protocol beyond event names already needed by this plan.

## Acceptance Criteria

- Each running session row can be expanded or opened to show a chronological state history.
- The history includes more than the latest state for a normal successful run.
- Startup failures, including Codex app-server failures, appear as visible state events instead of only terminal logs.
- Retry scheduling creates a history entry with attempt number and backoff delay.
- The existing running-session summary still shows the current state without requiring the history panel.
- The UI handles sessions with no detailed history by showing a clear empty state.
- Event payloads are bounded and do not expose known sensitive environment values.
- The implementation works with database persistence enabled.
- Tests cover event recording, ordering, bounded payload display, and dashboard rendering.

## Test Cases

- Start a run and emit multiple lifecycle updates; dashboard data contains ordered history entries for that run.
- Emit Codex session and turn updates; history shows `session_started`, `turn_started`, and terminal turn result in timestamp order.
- Simulate a Codex startup failure; history shows the failure state with bounded error context.
- Simulate a retry; history records retry attempt and delay.
- Render the dashboard with a running entry that has history; the expandable section contains all expected states.
- Render the dashboard with a running entry without history; the page remains usable and shows an empty-history message.
- Verify persisted event rows can be queried by `run_id` and transformed into the same presenter shape as in-memory events.
- Verify long payload strings are truncated before display.

## Implementation Notes

- Prefer building on the existing `events` table and `Persistence.record_event/1` instead of adding another session-history table unless the current schema cannot represent the needed query efficiently.
- Use stable event type names such as `run.started`, `workspace.created`, `codex.session_started`, `codex.turn_started`, `codex.turn_completed`, `run.retry_scheduled`, and `run.failed`.
- Keep the presenter boundary responsible for converting event records into UI-friendly history rows.
- Keep raw event payload maps out of templates; templates should receive normalized rows with fields such as:
  - `state`;
  - `label`;
  - `detail`;
  - `occurred_at`;
  - `severity`;
  - `metadata`.
- The in-memory runtime state should retain only a bounded per-session history so long-running agents cannot grow memory without limit.
- If persistence is enabled, use the database as the source of truth for historical rows and merge with in-memory updates only when needed for very fresh events.
- Avoid making the dashboard a log console. The history should be scoped to one session/run and should show lifecycle states, not arbitrary logger output.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

Delivered as bounded in-memory session history on running entries, projected through the API and rendered in an expandable dashboard section. Existing persistence still records run/codex/retry events, but the dashboard does not yet query historical rows from SQLite after a process restart.

## Dependencies

- Related to Task 004 persisted runtime state.
- Related to Task 012 worker result event reporting API.
- Related to Task 027 log-oriented status dashboard.
- Related to Task 053 Codex app-server startup error context.

## Handoff Notes

This plan should make runtime state transitions visible from the browser. It should not depend on reading Linear history, and it should not expose raw logs or raw Codex protocol messages. The expected user experience is: find the running session, expand it, and read the ordered lifecycle states that explain how the session reached its current state.
