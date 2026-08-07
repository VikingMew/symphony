# 062 Run Detail Observability Pages

## Goal

Add first-class operator pages for run detail, issue detail, events/logs, and workflow-version audit context.

Operators should be able to answer what happened for one issue or run without reading terminal logs: which workflow version was used, which Codex session and turns ran, which lifecycle events occurred, what failed, and whether a configuration change explains the behavior.

## Status

Completed.

## Background

The dashboard currently shows useful summaries and a bounded running-session history, but deeper debugging still requires stitching together multiple sources:

- dashboard running rows;
- persisted runs and task records;
- events rows;
- workflow versions;
- application logs;
- Linear comments and state.

Plan 054 made in-process running-session history visible, but its completion notes explicitly left SQLite-backed historical event browsing after restart as future work. The long-term direction also lists run detail, issue detail, events/logs pages, workflow diff, and run-bound workflow audit as still incomplete.

This plan turns that direction into an incremental Web UI slice.

## Scope

- Add a run detail page reachable from `/runs`.
- Add an issue detail page reachable from dashboard/runs when an issue identifier is available.
- Add an events/logs page for persisted Symphony events with pagination and basic filters.
- Show the workflow version attached to a run when available:
  - workflow version id/version/source;
  - active-at-run indicator when known;
  - raw workflow export/download or read-only preview if already supported by the persistence boundary;
  - summary of tracker/project/profile/runtime settings used by that version.
- Show run lifecycle information:
  - issue id and identifier;
  - status, attempt, worker host, workspace path;
  - started/finished timestamps and failure reason;
  - Codex session ids and agent turn summaries when available;
  - related persisted events in chronological order.
- Show issue-centric history:
  - current persisted issue snapshot;
  - associated runs;
  - associated events;
  - active/backoff/running state if still in memory.
- Normalize event payloads through a presenter layer before rendering.
- Bound displayed payload size and scrub known sensitive fields.
- Keep the main dashboard compact; deep detail belongs on dedicated pages.

## Out of Scope

- Building a full text log ingestion pipeline.
- Streaming raw application log files.
- Showing raw Codex JSON-RPC transcripts.
- Querying full Linear workflow history from Linear.
- Editing workflow versions from the detail pages.
- Implementing advanced search, retention, or saved filters.
- Changing dispatch, retry, or Linear transition behavior.

## Acceptance Criteria

- [x] `/runs/:id` or equivalent route renders one persisted run detail page.
- [x] `/issues/:identifier` or equivalent route renders one issue detail page.
- [x] `/events` or equivalent route renders persisted events with pagination and filters for issue/run/event type.
- [x] `/runs` links each run row to the run detail page.
- [x] The run detail page shows run metadata, related agent turns, related events, and workflow version context.
- [x] The issue detail page shows the current issue snapshot, associated runs, and associated events.
- [x] Event payloads are displayed through a bounded, scrubbed presenter representation.
- [x] Missing workflow version, missing events, or missing issue records render clear empty states.
- [x] Tests cover routing, rendering, empty states, payload bounding/scrubbing, and persistence-backed lookups.
- [x] Existing dashboard and workflow pages continue to render.

## Test Cases

- Persist a run with a workflow version and events; render run detail and assert all sections appear.
- Persist a run without workflow version; render run detail and assert an empty workflow-audit state appears.
- Persist an issue with multiple runs; render issue detail and assert runs are listed newest-first.
- Persist events for multiple issues; render events page with an issue filter and assert unrelated events are absent.
- Persist long or sensitive event payload fields; assert rendered payload is truncated and known secrets are redacted.
- Render `/runs` and assert run identifiers link to detail routes.
- Render detail pages with unknown ids and assert a 404 or clear not-found state.

## Implementation Notes

- Prefer extending existing LiveView/admin routes over adding a separate frontend stack.
- Add presenter functions for run detail, issue detail, workflow audit, and event rows rather than rendering raw Ecto structs or raw payload maps.
- Use the existing persistence provider boundary so tests can use fake persistence without starting the real Repo.
- If persistence lacks targeted lookup functions, add narrow functions such as:
  - `get_run(id)`;
  - `list_runs_for_issue(identifier)`;
  - `get_issue_by_identifier(identifier)`;
  - `list_events(filters)`;
  - `list_agent_turns_for_run(run_id)`.
- Keep pagination simple and deterministic for the first slice.
- When showing workflow diff, start with "run workflow vs current active workflow" summary if raw diff UI is too large for this plan. Full diff can be a follow-up.

## Verification

- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs` passed.
- `mise exec -- mix test` passed with 280 tests, 0 failures, 2 skipped.
- `mise exec -- mix lint` passed.
- `git diff --check` passed.

## Completion Deviations

Delivered as an incremental LiveView slice inside `AdminLive`. The `/events` page supports basic query-string filters and bounded result limits, but does not yet provide a richer paginated table component or full workflow diff UI. Run workflow audit shows version metadata; full version-to-version diff remains a follow-up.

## Dependencies

- Plan 004 persisted runtime state.
- Plan 027 log-oriented dashboard.
- Plan 054 running session state history.
- Existing workflow version persistence and export boundary.

## Handoff Notes

This plan is about observability after or during a run. It should not expand the main dashboard into a log console. The intended path is: summary page for scanning, detail pages for investigation.
