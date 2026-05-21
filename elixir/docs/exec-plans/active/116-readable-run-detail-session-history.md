# 116 Readable Run Detail Session History

## Goal

Make the run detail page readable enough for operators to understand what happened in a run without
opening raw event payloads or terminal logs.

## Status

Proposed.

## Background

Run detail pages and run-scoped historical session history already exist. Completed plan 062 added
`/runs/:id`, and completed plan 103 added a run-scoped persisted session-history query. The current
page is reachable, but the content is still hard to use in real debugging:

- run metadata is rendered as a sparse raw table;
- workflow version is rendered as an inspected map instead of an operator summary;
- agent turns often show an empty state even while useful persisted events exist;
- historical `codex.update` rows render as repeated generic `Codex update` / `codex.update`
  entries instead of human-readable details;
- the session history table has no grouping, severity emphasis, payload expansion, or filtering;
- timestamps are raw ISO strings and do not help operators scan duration or phase order quickly.

In the observed CCR-5 run, the user could click into the detail page, but the page did not clearly
answer why the run was blocked or what the agent reported.

## Scope

- Improve `RunHistory` transformation for persisted `codex.update` events:
  - preserve and parse both string and atom event names;
  - pass `%{event: ..., message: ...}` through the existing Codex humanizer;
  - render streaming agent message fragments as readable/coalesced text when persisted data allows.
- Improve run detail presentation:
  - replace the raw workflow-version inspected map with concise fields and links/context;
  - show status, attempt, duration, worker host, workspace path, failure reason, and run id clearly;
  - make important failure/blocker rows visually distinct.
- Add a readable session-history section:
  - chronological timeline;
  - source badges using the same semantics as live session history;
  - event labels that reflect the underlying operation;
  - details that include command names, tool names, blocked reasons, branch/push failures, and
    summarized agent messages when available.
- Add bounded metadata expansion for rows where detail is not enough.
- Preserve the generic `/events` table as the raw audit view.
- Add tests that assert useful run detail content, not only route existence.

## Out of Scope

- Do not add a full log ingestion pipeline.
- Do not query Linear history live from the run detail page.
- Do not redesign the whole dashboard navigation.
- Do not change orchestration, retry, push, or state-transition behavior.
- Do not expose unbounded raw Codex JSON-RPC transcripts.

## Acceptance Criteria

- Opening `/runs/:id` for a historical run shows human-readable session history details for
  persisted `codex.update` events.
- Repeated persisted agent message fragments do not render as a wall of identical `codex.update`
  rows when enough payload data exists to summarize or coalesce them.
- A run blocked by push/network/sandbox failure shows that blocker in the detail text.
- Workflow version context is shown as operator-facing fields rather than an inspected Elixir map.
- A run with no agent turns but with persisted events still has a useful timeline.
- Raw payloads remain bounded and scrubbed.
- `/events` remains available for raw event auditing.

## Test Cases

- `RunHistory.from_event/1` transforms a persisted `codex.update` with an atom or string event into a
  human-readable detail using `StatusDashboard.humanize_codex_message/1`.
- `RunHistory.from_event/1` transforms an agent message delta/update into visible text when the
  payload contains a fragment or message content.
- `/runs/:id` renders readable details for a fake run with persisted Codex updates.
- `/runs/:id` does not show only `codex.update` as the detail for Codex rows when message payloads
  are available.
- `/runs/:id` renders workflow version id/version/source/active/inserted fields without using raw
  `inspect` map formatting.
- Existing `/events` filtering and raw payload display tests still pass.

## Implementation Notes

- Start with `SymphonyElixir.RunHistory`; the page should not hand-roll Codex payload parsing.
- Reuse `StatusDashboard.humanize_codex_message/1` instead of adding another Codex protocol
  formatter.
- Check the persisted payload shape written by `Orchestrator.persist_codex_update/2`:

```elixir
%{event: Map.get(update, :event), message: Map.get(update, :message)}
```

- `RunHistory.detail/2` currently falls back to the event type when no top-level `message`, `detail`,
  or `output` is found. That is why many rows render as `codex.update`.
- If persisted streaming fragments are too granular, coalesce adjacent rows only within the same run,
  source, event, and operation, and preserve the raw event count.
- Keep the UI compact first; richer timeline components can follow after the transformation is
  correct.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`
- Manual check: open `/runs/:id` for a run with persisted Codex updates and confirm the detail column
  explains the agent activity/blocker instead of repeating `codex.update`.

## Completion Deviations

None yet.

## Dependencies

- Completed plan 062 for run detail pages.
- Completed plan 103 for run-scoped historical session event query.
- Existing `StatusDashboard.humanize_codex_message/1` Codex message presentation logic.

## Handoff Notes

This is not a missing route problem. The page exists and is clickable. The bug is that the detail
page does not yet turn persisted run/session events into an operator-readable investigation view.
