# 194 Runs Page Infinite Scroll Pagination

## Goal

Make the `/runs` page fast by loading persisted runs incrementally instead of rendering a large fixed list on initial page load.

The page should support scroll/load-more behavior with stable ordering and filters, so operators can inspect historical runs without paying the full cost upfront.

## Status

Completed.

## Background

The current Runs page is rendered by `SymphonyElixirWeb.AdminLive` and assigns:

```elixir
persistence().list_runs(limit: 100)
```

That means opening `/runs` loads and renders a fixed batch of records immediately. As the persisted run table grows, this becomes slow and makes the page feel heavy even when the operator only needs the latest few runs.

The list also sits in the same broad LiveView as several other observability/settings surfaces. Completed plans improved run detail readability, but the list page still behaves like a small static admin table rather than a scalable operations log.

This plan adds paginated loading for the run list. Run detail pages remain separate and should keep loading their selected run's session history/events on demand.

## Scope

- Add a paginated run listing query to persistence.
- Prefer keyset/cursor pagination over offset pagination for stable performance:
  - order by `inserted_at desc`, then `id desc` as a deterministic tie-breaker;
  - return a next cursor when more rows exist.
- Update `/runs` LiveView state to keep:
  - loaded rows;
  - page size;
  - next cursor;
  - loading state;
  - end-of-list state.
- Add a "Load more" action and/or scroll-triggered loading using LiveView hooks.
- Keep initial page load small, for example 25 rows by default.
- Preserve direct links from each run row to `/runs/:id`.
- Keep the table readable while loading more rows.
- Add empty, loading, exhausted, and error states.
- Ensure filters, if present or later added through analytics links, work with pagination:
  - status;
  - execution mode;
  - project id;
  - issue identifier;
  - failure reason.
- Add tests for persistence cursor behavior and rendered LiveView load-more behavior.

## Out of Scope

- Redesigning the run detail page.
- Loading run session history on the list page.
- Adding full-text search.
- Adding arbitrary sort controls beyond stable newest-first ordering.
- Replacing `/events` pagination/filtering.
- Splitting `AdminLive` into a new Runs LiveView unless the implementation chooses that as a contained route extraction.

## Acceptance Criteria

- `/runs` initial render loads a small bounded page of run rows, not a fixed 100-row table.
- The page can load additional rows without a full browser refresh.
- Rows remain ordered newest-first across page boundaries.
- Duplicate rows do not appear when loading more.
- The page clearly indicates when there are no more runs.
- Existing `/runs/:id` links continue to work.
- Existing issue-backed run rows continue to show issue links when issue identifiers exist.
- Operator/no-issue runs from plan 193, if present, render without breaking pagination.
- Persistence query supports filters and cursor pagination together.
- Tests cover more-than-one-page run lists.

## Test Cases

- Persistence test:
  - create more runs than the page size;
  - fetch first page;
  - fetch next page using cursor;
  - assert no overlap and correct newest-first order.
- Persistence tie-break test:
  - create runs with identical `inserted_at`;
  - assert `id` tie-breaker keeps pagination deterministic.
- Persistence filter test:
  - filter by `status`;
  - assert cursor pagination only returns matching rows.
- LiveView render test:
  - with 60 persisted runs and page size 25, initial `/runs` shows 25 rows and a load-more control.
- LiveView load-more test:
  - trigger load-more;
  - assert row count increases and existing rows are preserved.
- End-of-list test:
  - load until no cursor remains;
  - assert the page shows a no-more-runs state and disables/hides load-more.
- Empty-state test:
  - no persisted runs renders a fast empty state.
- Regression test:
  - row links still point to `/runs/:id`.

## Implementation Notes

- Add persistence API such as `list_runs_page(opts)` returning:

```elixir
%{
  entries: runs,
  next_cursor: cursor_or_nil,
  has_more?: boolean
}
```

- Cursor can be an opaque encoded value containing `inserted_at` and `id`. Keep parsing/validation bounded and reject malformed cursors safely.
- Fetch `page_size + 1` rows to determine `has_more?`.
- Avoid preloading heavy associations for the list. The run detail page can load workflow version, turns, events, and session history separately.
- Keep list rows lightweight:
  - run id;
  - issue/operator label;
  - status;
  - attempt;
  - started;
  - finished;
  - duration if cheap.
- If a LiveView JS hook is used for infinite scroll, keep a visible `Load more` fallback for accessibility and deterministic tests.
- Consider moving run-list derivation into an observability presenter if it reduces `AdminLive` template logic, but do not make that extraction the main risk of this plan.
- If filters are already accepted through query params from analytics links, reset loaded rows and cursor whenever filters change.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir_web/live/observability_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`
- Browser verification:
  - seed more than one page of runs;
  - open `/runs`;
  - confirm initial render is fast;
  - load additional pages by scroll or button;
  - confirm row order and detail links remain correct.

## Completion Deviations

None.

## Dependencies

- Completed plan 062 for run detail observability pages.
- Completed plan 103 for run-scoped session history query.
- Completed plan 116 for readable run detail session history.
- Completed plan 141 for run detail execution summary.
- Completed plan 166 for observability presenter boundary.
- Completed plan 180 for observability test split.
- Completed plan 193 for operator/no-issue runs, which should not break the paginated row model.

## Handoff Notes

Keep the list page cheap. `/runs` should answer "what happened recently?" without loading every historical detail. Operators can drill into `/runs/:id` for expensive session history, raw events, workflow version context, and summaries.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

