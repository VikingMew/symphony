# 118 Run Detail Codex History Signal

## Goal

Make the run detail page useful for post-run debugging by preserving and presenting the actual Codex activity signal instead of showing a wall of repeated `codex.update` rows with empty payloads.

## Status

Completed.

## Background

Completed plan 116 claimed the run detail page had been made readable, but a real CCR-5 completed run still shows little operational value:

- `Agent Turns` says no turns were recorded.
- `Session History` is dominated by repeated `Codex notification` rows.
- Most details are just `codex.update`.
- Expanded payloads often contain only `%{"event" => "notification", "message" => nil}`.
- The raw `Events` table repeats the same low-signal rows.
- The page does not answer what the agent did, what tools ran, what final summary was produced, or whether there were blockers.

This is a follow-up to plan 116 because its acceptance criteria are not met by the observed page.

The core data-loss bug is in `SymphonyElixir.Orchestrator.persist_codex_update/2`. The live in-memory dashboard uses `summarize_codex_update(update)`, which reads `update[:payload] || update[:raw]`. The persisted event path currently writes only:

```elixir
%{event: Map.get(update, :event), message: Map.get(update, :message)}
```

For many Codex updates, `:message` is absent while the meaningful content is in `:payload` or `:raw`. Once persisted as `message: nil`, `RunHistory` cannot recover the lost detail later. Presentation improvements alone cannot fix historical runs whose content was never stored.

## Scope

- Fix Codex update persistence so future run history stores enough structured data to explain the run:
  - event name;
  - timestamp;
  - session id;
  - normalized message derived from `payload` or `raw`;
  - bounded raw/debug context where useful and safe.
- Keep persisted payloads bounded and scrubbed so the events table does not become an unbounded transcript store.
- Update `RunHistory` so it can read both legacy payloads and the improved payload shape.
- Improve run detail presentation so low-signal Codex notification rows do not dominate the page:
  - coalesce adjacent streaming/notification rows more aggressively when they are semantically identical;
  - show tool calls, command starts/ends, final messages, errors, and completion events as first-class timeline entries;
  - hide or collapse empty notification rows by default when they add no information.
- Add a compact run summary above the timeline:
  - run outcome;
  - last useful Codex message;
  - command/tool highlights;
  - blockers or failure reason when present;
  - token/turn/session information when available.
- Make `Agent Turns` either reliably populated or remove/reframe the section so it does not imply missing data when only event-history data exists.
- Preserve `/events` as the raw audit table, but make it clear it is raw and secondary.

## Out of Scope

- Do not attempt to reconstruct detailed content for old runs where only `message: nil` was persisted.
- Do not store unbounded Codex JSON-RPC transcripts.
- Do not change Codex execution behavior.
- Do not change merge, retry, or Linear state-transition semantics.
- Do not remove the raw event audit table.

## Acceptance Criteria

- A newly completed run shows a readable timeline that includes meaningful Codex activity instead of mostly `codex.update`.
- Persisted `codex.update` rows retain useful details when the original update contains `payload` or `raw` but no `message`.
- Empty `notification` rows with no useful message/detail are collapsed, hidden, or summarized instead of repeated dozens of times.
- The run detail page clearly shows the final Codex completion event or final agent summary when available.
- The page clearly shows tool/command activity when Codex emits tool or command events.
- `Agent Turns` no longer presents a misleading empty state when session history is the available source of truth.
- Legacy runs with `message: nil` degrade honestly, with a visible note that detailed Codex payloads were not persisted for those rows.
- Raw `/events` still exposes bounded/scrubbed payloads for audit.

## Test Cases

- `persist_codex_update/2` stores a Codex notification whose useful content is in `payload`, not `message`.
- `persist_codex_update/2` stores a Codex update whose useful content is in `raw`, not `message`.
- Persisted payloads remain bounded and do not include known sensitive fields.
- `RunHistory.from_event/1` humanizes the improved persisted payload shape.
- `RunHistory.from_event/1` handles legacy `%{"event" => "notification", "message" => nil}` without crashing and marks it as low-signal.
- `RunHistory.list_run_session_events/3` coalesces repeated empty notification rows.
- `/runs/:id` renders a useful summary for a run with command/tool/final-message Codex events.
- `/runs/:id` does not render a long wall of identical `Codex notification` rows for low-signal events.
- `/events` continues to show bounded raw payloads.

## Implementation Notes

Start at the persistence boundary, not the UI. Once `message: nil` is written, the page cannot infer what the agent did.

Recommended payload shape:

```elixir
%{
  event: Map.get(update, :event),
  message: update[:message] || update[:payload] || update[:raw],
  timestamp: update[:timestamp],
  session_id: update[:session_id]
}
```

Then apply bounded/scrubbed storage before calling `record_event/1`.

Reuse existing humanization logic:

- `SymphonyElixir.StatusDashboard.humanize_codex_message/1`
- existing `RunHistory` transformation boundary
- existing payload scrub/bound helpers where possible

Avoid making the run detail page parse raw Codex protocol directly in the LiveView template. Keep parsing and coalescing in `RunHistory` or a nearby presenter module.

For historical rows that already contain only `message: nil`, prefer a concise placeholder such as `Empty Codex notification; detailed payload was not persisted` and group repeated rows into one summary like `84 empty Codex notifications`.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- Focused orchestrator persistence test for Codex updates with `payload`/`raw`.
- Web test for `/runs/:id` with meaningful persisted Codex events.
- Manual check: run detail for a new completed run shows a readable summary and timeline, not a wall of `codex.update`.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

- Added a compact `Run Summary` table on the existing run detail page instead of introducing a new
  presenter module or separate detail page.
- Low-signal legacy `message: nil` Codex notifications are collapsed into a single summarized row;
  raw `/events` still shows the original bounded audit records.
- Structured agent turns were not backfilled. The empty state now explains that session history is
  the source of truth when no turn rows exist.

## Dependencies

- Completed plan 062 for run detail pages.
- Completed plan 103 for run-scoped event-history queries.
- Completed plan 116 for the first run-detail readability pass.

## Handoff Notes

Treat the user-provided CCR-5 run detail as a failed acceptance example for plan 116. The UI cannot become useful until Codex update persistence keeps the actual payload/raw message content. Fix persistence first, then improve `RunHistory` coalescing and the run detail presentation.
