# 067 Session History Notification Coalescing

## Goal

Reduce session-history noise by coalescing adjacent Codex notification events
that are fragments of the same streaming agent message.

## Status

Completed.

## Background

After session-history details were made observable, Codex streaming output can
produce one history row per token or small text fragment:

```text
Notification 2026-05-09T06:27:17Z agent message streaming: I
Notification 2026-05-09T06:27:17Z agent message streaming: 'm
Notification 2026-05-09T06:27:17Z agent message streaming: checking
Notification 2026-05-09T06:27:17Z agent message streaming: the
Notification 2026-05-09T06:27:17Z agent message streaming: full
```

These rows prove the run is alive, but they make the session history hard to
scan and can push more useful lifecycle events out of the 100-row visible
window. The UI should show the accumulated streaming message as a single
logical row when the notifications are adjacent and clearly part of the same
agent message stream.

## Scope

- Coalesce adjacent `:notification` session-history entries when they represent
  the same Codex agent-message streaming item.
- Preserve non-streaming notification entries as individual events.
- Preserve lifecycle events such as run started, workspace ready, Linear
  transition, session started, tool calls, command approvals, and item
  completions as separate history rows.
- Preserve activity tracking semantics: each raw Codex update must still refresh
  `last_codex_timestamp` so the stall watchdog observes real activity.
- Keep a count of coalesced fragments in the session-history metadata or detail
  so operators can see that multiple raw events were folded into one row.
- Update the total session-history count behavior intentionally:
  - either keep total count as raw observed events and label the UI accordingly;
  - or store both raw count and visible/coalesced count.
- Add regression tests covering adjacent streaming fragments, separated
  fragments, and non-streaming notifications.

## Out of Scope

- Changing the Codex app-server protocol parser.
- Dropping raw persisted runtime events from the event log.
- Aggregating unrelated notification methods.
- Increasing or removing the 100-row visible session-history window.
- Full run-detail log search or pagination.

## Acceptance Criteria

- A sequence of adjacent agent-message streaming notification fragments appears
  as one session-history row with combined readable text.
- The combined row retains the first event timestamp, updates last activity from
  the newest raw event, and records the number of folded fragments.
- A non-streaming notification is not merged into a streaming message row.
- A lifecycle event between two streaming fragments prevents those fragments
  from being merged across the lifecycle boundary.
- `last_codex_timestamp` still advances on every incoming Codex update,
  including updates folded into an existing history row.
- The dashboard summary makes clear when the visible history is coalesced or
  when the raw event count is larger than visible rows.
- Focused orchestrator/presenter tests pass.
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
  passes.
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs` passes.
- `mise exec -- mix lint` passes.
- `mise exec -- mix test` passes.

## Test Cases

- Feed three adjacent `:notification` updates with agent-message streaming
  fragments `I`, `'m`, and `checking`; the snapshot has one visible history row
  with detail equivalent to `agent message streaming: I'm checking`.
- Feed a streaming fragment, then `:tool_call_completed`, then another streaming
  fragment; the two streaming rows remain separate around the tool event.
- Feed two generic notification methods that are not agent-message streaming;
  they remain two rows.
- Feed streaming fragments past the visible history limit; visible rows remain
  bounded, while the raw/coalesced counts stay accurate.
- Verify the stall timestamp advances after every folded streaming fragment.

## Implementation Notes

- The likely implementation point is `Orchestrator.append_codex_history/2` or
  `append_session_history/4`, where the system already owns the 100-row visible
  window.
- Detect streaming agent-message notifications using the humanized detail or,
  preferably, the raw Codex payload shape if it is stable enough in
  `StatusDashboard.humanize_codex_message/1`.
- Avoid merging by generic label alone. `Notification` is too broad and includes
  different protocol conditions.
- Store enough metadata for debugging, for example:
  - `coalesced_event_count`;
  - `coalesced_last_at`;
  - last raw payload summary or last fragment.
- Keep persisted event logs raw if they are already recorded elsewhere; the
  coalescing target is the dashboard session-history list.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
  - 36 tests, 0 failures
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
  - 13 tests, 0 failures
- `mise exec -- mix lint`
  - no issues
- `mise exec -- mix test`
  - 288 tests, 0 failures, 2 skipped

## Completion Deviations

- The delivered implementation keeps `session_history_total_count` as the raw
  observed event count while reducing visible rows through coalescing.
- The dashboard summary now says `<visible> rows from <total> events` when raw
  event count is larger than visible history rows. This covers both coalescing
  and the existing visible-window truncation case without adding a second count
  field.
- Coalescing is limited to adjacent agent-message streaming notification methods
  recognized by raw Codex payload method names.

## Dependencies

- Completed plan
  [066-session-history-observable-details.md](../completed/066-session-history-observable-details.md).
- Existing `StatusDashboard.humanize_codex_message/1` behavior for streaming
  agent-message details.
- Existing `@session_history_limit` handling in `SymphonyElixir.Orchestrator`.

## Handoff Notes

Do not solve this by filtering all notifications. Notifications are the current
proof that Codex is alive and must continue to refresh activity timestamps.
Only adjacent fragments of the same streaming message should be folded for
display.
