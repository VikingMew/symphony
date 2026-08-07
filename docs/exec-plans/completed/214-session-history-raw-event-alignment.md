# 214 Session History Raw Event Alignment

## Goal

Align run detail `Session History`, `Agent Summary`, and `Raw Events` so they describe the same underlying Codex and Symphony events.

Raw persisted events should be the durable source of truth. Session history should be a readable projection of those events, not a separate, partially divergent event stream.

## Status

Completed.

## Background

A completed `NAP-*` run showed useful, complete raw events:

- `item/completed` with final agent message: created `CCR-29` through `CCR-32`;
- `thread/tokenUsage/updated` with full token totals in raw debug data;
- `account/rateLimits/updated`;
- `thread/status/changed`;
- `turn/completed`;
- `run.completed`.

However, the operator-facing `Session History` did not line up cleanly with `Raw Events`. The two views can differ in:

- which Codex protocol events appear;
- ordering and timestamps;
- whether final answers are visible;
- whether session/turn ids are present;
- whether token usage appears as a readable signal;
- whether low-level notifications are coalesced or hidden;
- how much payload is truncated.

The current code has multiple projection paths:

- live running state is updated by `SymphonyElixir.Codex.Update`;
- historical run detail is produced by `SymphonyElixir.RunHistory`;
- raw events are rendered by the events table through `EventPresenter`;
- summaries are derived by `RunSummary`;
- Linear tool calls are now separately audited as `linear.tool_call`.

This means a run can be successful in raw events while session history still looks incomplete or inconsistent. That is especially damaging for `nap` and `day_dreaming`, where the important output is what the agent found and what Linear issues it created.

## Scope

- Establish persisted raw events as the source of truth for completed run detail.
- Introduce or consolidate a single historical event projector used by:
  - run detail `Session History`;
  - `Agent Summary`;
  - event row detail for run-scoped views where practical.
- Ensure the projector handles key Codex protocol methods:
  - `item/started`;
  - `item/completed`;
  - `item/agentMessage/delta`;
  - `item/tool/call`;
  - tool completed/failed events;
  - `thread/tokenUsage/updated`;
  - `account/rateLimits/updated`;
  - `thread/status/changed`;
  - `turn/completed`;
  - malformed or unknown events.
- Preserve final agent messages as first-class session history rows:
  - final answer text must appear in run detail;
  - long final answers must be bounded with explicit truncation metadata, not silently lost.
- Preserve successful Linear issue creation evidence:
  - created issue identifiers;
  - titles;
  - URLs;
  - source operator run/profile.
- Preserve failed Linear tool calls with normalized failure class and safe input summary.
- Align timestamps:
  - prefer protocol event timestamps when present;
  - otherwise use persisted event `occurred_at`;
  - never use projection time as the visible event time for historical run detail.
- Align session and turn identity:
  - extract `threadId`, `turnId`, and session id from payloads when available;
  - avoid showing `session_id: nil` when the raw payload contains enough data to derive it.
- Make intentional filtering explicit:
  - if low-signal notifications are hidden or coalesced, the UI should say how many raw events were summarized;
  - raw events remain available below for audit.
- Keep sensitive data scrubbed:
  - token usage may be summarized numerically;
  - raw token usage should remain redacted where policy requires;
  - secrets must not be exposed in metadata.

## Out of Scope

- Replacing the raw events table.
- Persisting every full raw protocol payload without bounds.
- Changing Codex upstream protocol semantics.
- Changing Linear issue creation policy.
- Reworking the entire observability UI layout beyond the alignment needed here.
- Making live Dashboard running history identical to completed run detail when the live view intentionally keeps only a bounded recent window.

## Acceptance Criteria

- For a completed run, `Session History` is derived from the same persisted events shown in `Raw Events`.
- A final `item/completed` agent message appears as a readable final-answer row in session history and summary.
- A `turn/completed` raw event appears as a readable turn-completed row in session history.
- A `thread/tokenUsage/updated` raw event appears as a readable token-usage row or token summary.
- A `account/rateLimits/updated` raw event appears as a readable rate-limit row.
- Linear tool success/failure events appear in session history with the same result as raw `linear.tool_call` events.
- The ordering of session history rows matches raw event chronological ordering after coalescing.
- Session/turn ids shown in metadata are derived from raw payloads when available.
- Any coalescing or filtering reports the raw-event count it summarized.
- Raw events and session history no longer contradict the run outcome for successful `nap` and `day_dreaming` runs.

## Test Cases

- Historical projection test:
  - feed persisted raw events for `item/completed` final answer, token usage, rate limit update, thread idle, turn completed, and run completed;
  - assert session history includes readable rows for each important event in chronological order.
- Final-answer test:
  - feed a long `item/completed` final answer;
  - assert summary captures the final answer and metadata records whether display text was truncated.
- Token usage test:
  - feed `thread/tokenUsage/updated` with token totals;
  - assert session history or summary shows total/input/output values without exposing unsanitized raw payload.
- Session id derivation test:
  - feed raw payloads with `threadId` and `turnId` but no explicit persisted `session_id`;
  - assert projected metadata includes derived session/turn identifiers.
- Linear issue success test:
  - feed `linear.tool_call` success for `linear_issue_create`;
  - assert session history and summary show created issue identifier and URL.
- Linear issue failure test:
  - feed `linear.tool_call` failure;
  - assert failure class and safe input summary are visible.
- Coalescing test:
  - feed many streaming deltas and low-signal notifications;
  - assert coalesced row reports fragment/event count and raw events remain available.
- Ordering test:
  - feed events out of insertion order but with timestamps;
  - assert session history sorts by event time.
- Regression test:
  - existing issue-backed runs still show workspace phases, Codex messages, Linear state transitions, and completion.

## Implementation Notes

- Prefer extending `RunHistory.from_events/1` into the canonical completed-run projector.
- Avoid duplicating Codex method parsing in both `RunHistory` and `Codex.Update`. If live state still needs a bounded recent history, share the method-humanization and metadata extraction functions.
- Add explicit handlers for protocol methods currently falling through to generic `codex.update`, especially:
  - `item/completed` for `agentMessage` final answers;
  - `thread/tokenUsage/updated`;
  - `account/rateLimits/updated`;
  - `turn/completed`.
- Do not use `DateTime.utc_now()` while projecting historical events. Use persisted event time or protocol timestamp.
- Use stable row types or metadata fields so `RunSummary` can reliably identify:
  - final answer;
  - tool calls;
  - commands;
  - token usage;
  - rate-limit updates;
  - blockers/failures.
- Keep raw event rendering available as the audit trail, but make `Session History` the readable version of the same trail.

## Verification

- Run focused tests for `RunHistory.from_events/1` using realistic `NAP-*` raw event payloads.
- Run focused tests for `RunSummary.summarize/2` against the same projected rows.
- Run run-detail LiveView tests proving session history, agent summary, and raw events agree.
- Run event presenter tests to ensure raw payload disclosure remains bounded and scrubbed.
- Run `mise exec -- mix test`.
- Run `mise exec -- mix exec_plans.check`.
- Browser verification:
  - open a completed `nap` run detail;
  - confirm final answer, created Linear issues, token usage, rate limits, and turn completion appear in session history/summary;
  - confirm raw events still show the backing payloads.

## Completion Deviations

None.

## Dependencies

- Completed plan 116 for readable run detail session history.
- Completed plan 141 for agent execution summary.
- Completed plan 213 for Linear tool context and result capture.
- Completed plan 156 for known rate-limit payload rendering.
- Completed plan 209 for analytics token accuracy.

## Handoff Notes

The concrete symptom is not that raw events are missing. The raw events contain the useful facts. The problem is that the readable run-detail views do not project those facts consistently.

Fix the projector boundary: completed run detail should be able to explain the run from persisted events alone, and every readable row should be traceable back to one or more raw events.

Completed verification:

- 2026-05-23: `mise exec -- mix format lib/symphony_elixir/run_history.ex lib/symphony_elixir/run_summary.ex test/symphony_elixir/run_history_test.exs --check-formatted`
- 2026-05-23: `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- 2026-05-23: `mise exec -- mix test test/symphony_elixir/run_summary_test.exs test/symphony_elixir_web/live/observability_fake_persistence_test.exs`
