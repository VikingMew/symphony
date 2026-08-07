# 133 Events Page Signal and Filtering

## Goal

Turn the `/events` page from a low-signal raw table into a usable audit and troubleshooting surface while preserving access to bounded raw payloads.

Operators should be able to identify important failures, run boundaries, Linear activity, workspace phases, and meaningful Codex events without paging through hundreds of identical empty `codex.update` rows.

## Status

Completed.

## Background

The current `/events` page renders persisted events as a simple table with filters for issue, run id, event type, and limit. In real runs it often shows rows like:

```text
codex.update  %{"event" => "notification", "message" => nil}
codex.update  %{"event" => "notification", "message" => nil}
codex.update  %{"event" => "notification", "message" => nil}
```

This is technically an audit view, but it does not provide reliable debugging information:

- repeated empty Codex notifications dominate the table;
- payloads are raw inspected maps rather than useful summaries;
- severity is not visible;
- event source is not visible;
- issue and run identifiers are not navigable;
- there are no quick filters for high-value event categories;
- important failures are not visually distinct;
- the page does not explain when rows are low-signal because older persistence dropped Codex payload content.

Active plan 118 owns the upstream Codex history signal issue: future `codex.update` rows must persist useful `payload`/`raw` message data. This plan owns the `/events` page presentation and filtering layer. It should work better with both improved future payloads and legacy low-signal rows.

## Scope

- Keep `/events` as the raw audit page, but add an operator-readable summary layer.
- Add normalized event presentation fields:
  - source (`system`, `agent`, `linear`, `workspace`, `worker`, `unknown`);
  - severity (`info`, `warning`, `error`);
  - summary/detail;
  - low-signal marker;
  - related run/issue links when available.
- Add filter controls or quick chips for common investigations:
  - failures/errors only;
  - run lifecycle;
  - workspace events;
  - Linear events;
  - Codex tool/command events;
  - hide low-signal Codex notifications;
  - show only a specific issue/run.
- Default behavior should reduce noise:
  - collapse or hide repeated empty Codex notification rows by default;
  - show a count of hidden/collapsed low-signal rows;
  - allow users to reveal raw/low-signal rows when they need full audit detail.
- Make important rows visually scannable:
  - failed/stopped events use error/warning styling;
  - run boundaries are distinct;
  - workspace and Linear events have clear labels.
- Add navigation:
  - issue id links to `/issues/:identifier`;
  - run id links to `/runs/:id`;
  - event type chips can apply that event filter.
- Preserve bounded/scrubbed raw payload expansion for each row.
- Add tests for filtering, summarization, low-signal hiding, and links.

## Out of Scope

- Do not store unbounded raw Codex transcripts.
- Do not remove raw payload access.
- Do not replace run detail pages.
- Do not add full-text search across all payload fields unless it is trivial and bounded.
- Do not reconstruct detailed content for old events whose persisted payload is only `message: nil`.
- Do not change event persistence semantics except where plan 118 or related persistence work already owns it.

## Acceptance Criteria

- `/events` no longer defaults to a wall of identical empty `codex.update` rows.
- The page clearly reports how many low-signal rows were hidden or collapsed.
- Users can reveal low-signal/raw rows when needed.
- Failure and warning events are visually distinct.
- Each row has a readable summary/detail separate from raw payload.
- Issue identifiers link to issue detail pages.
- Run ids link to run detail pages.
- Filters support at least:
  - issue;
  - run id;
  - event type;
  - severity/errors;
  - hide/show low-signal rows.
- Legacy empty Codex notification rows render with an honest explanation, such as `Empty Codex notification; detailed payload was not persisted`.
- Raw payloads remain bounded and scrubbed.

## Test Cases

- Events page with repeated legacy empty Codex notifications:
  - default view collapses or hides them;
  - page shows hidden/collapsed count;
  - reveal action shows bounded raw rows.
- Events page with `run.failed`:
  - row is marked error;
  - summary includes failure reason when present.
- Events page with workspace failure:
  - row is marked error;
  - summary includes phase/operation and recent output when available.
- Events page with Linear state transition:
  - row source is Linear;
  - summary shows `from -> to`.
- Events page with meaningful future `codex.update` payload:
  - summary uses existing Codex humanization;
  - raw payload remains expandable.
- Issue and run links:
  - issue id links to `/issues/:identifier`;
  - run id links to `/runs/:id`.
- Filter tests:
  - errors-only filter excludes info rows;
  - event-type chip/filter narrows rows;
  - hide-low-signal toggle changes visible row count.

## Implementation Notes

Prefer reusing or extracting a shared event presentation boundary rather than duplicating formatting in the LiveView template.

Candidate boundaries:

- `SymphonyElixir.RunHistory` already converts persisted events into readable timeline rows for run detail.
- A new `SymphonyElixir.EventHistory` or `SymphonyElixir.EventPresenter` could provide page-neutral normalized event rows for both `/events` and run detail.

Do not make the LiveView template parse raw payload shapes directly. The template should render normalized fields and expandable metadata.

Low-signal criteria should be explicit and tested. Examples:

- `event_type == "codex.update"`;
- payload event is `notification`;
- payload message/detail is nil or blank;
- no command/tool/method/rate-limit/session information exists.

If rows are collapsed, preserve audit access by including:

- count;
- time range;
- issue/run scope;
- a reveal option.

The existing filters can remain as URL query params. Add new params conservatively, for example:

- `severity=error`;
- `hide_low_signal=true`;
- `source=linear`;
- `category=workspace`.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/event_presenter_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- Focused event presentation tests cover severity/source/summary/low-signal classification.
- Focused LiveView/Admin tests cover `/events` filtering, links, default low-signal hiding, reveal behavior, errors-only filtering, Linear filtering, and scrubbed raw payload expansion.
- Existing run detail coverage remained in the focused web persistence test command because `/runs/:id` also renders event history.
- `mise exec -- mix test --cover` passed with 432 tests, 0 failures, 2 skipped, 85.75% total coverage.
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

Delivered as a default hide/reveal filter rather than a grouped time-range collapse. This keeps full audit access through `hide_low_signal=false` while avoiding additional grouping state in the LiveView.

## Dependencies

- Active plan 118 for future Codex update payload persistence.
- Completed plan 062 for run detail pages.
- Completed plan 103 for run-scoped session event query.
- Existing `/events` route and bounded payload rendering.

## Handoff Notes

Preserve `/events` as an audit surface, but make the default view answer operator questions. Raw data should remain available on demand; it should not be the only thing the page can show.
