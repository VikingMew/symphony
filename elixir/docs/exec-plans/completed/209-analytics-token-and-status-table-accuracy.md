# 209 Analytics Token And Status Table Accuracy

## Goal

Fix the Analytics page so historical `Total tokens` reflects real persisted Codex token usage, and simplify the Status breakdown table by removing the redundant `Completed` column.

The Status table is already grouped by status. A row named `completed` does not need a `Completed` column that repeats the same fact.

## Status

Completed.

## Background

The Analytics page was added as a database-backed historical view over persisted runs, events, projects, and agent turns. It currently derives token totals by scanning event payloads and looking for a small set of token shapes such as:

- `payload["tokens"]`;
- `payload["params"]["tokens"]`;
- `payload["params"]["total_token_usage"]`;
- nested `message.params` variants.

Real persisted Codex update events have evolved. Runtime token accounting already recognizes shapes such as `params.tokenUsage.total`, wrapped `params.msg.payload.info.total_token_usage`, and other Codex wrapper payloads. The Dashboard can show token totals while Analytics still reports zero because Analytics is not using the same token extraction contract.

Separately, `AnalyticsLive.breakdown/1` renders every breakdown table with the same columns:

- `Name`;
- `Runs`;
- `Completed`;
- `Failed`;
- `Blocked`.

That is reasonable for project/issue/execution-mode breakdowns, where each row can contain mixed statuses. It is redundant for the Status breakdown because each row is itself a status. In the Status table, the `completed` row makes the `Completed` column tautological and adds noise.

## Scope

- Make Analytics token extraction consume the same real Codex token payload shapes as runtime token accounting.
- Prefer sharing or reusing a token extraction helper rather than maintaining a divergent parser inside `Analytics`.
- Ensure Analytics counts persisted historical token usage from events that contain:
  - `params.tokenUsage.total`;
  - `params.total_token_usage`;
  - `params.msg.payload.info.total_token_usage`;
  - `params.msg.info.total_token_usage`;
  - existing `tokens` test fixture shapes.
- Avoid double-counting cumulative token totals within a single run/session if multiple monotonic token snapshots are persisted.
- Define whether Analytics totals are:
  - event-sum totals for token delta events; or
  - per-run maximum cumulative totals.
- Implement that definition consistently and test it with repeated cumulative snapshots.
- Adjust the Analytics Status breakdown UI so it does not render the `Completed` column.
- Keep `Completed`, `Failed`, and `Blocked` columns for non-status breakdown tables where they remain meaningful.
- Add focused unit and rendered LiveView tests.

## Out of Scope

- Redesigning the whole Analytics page.
- Adding charts.
- Persisting new token columns if existing events already contain enough historical data.
- Changing Dashboard live token accounting.
- Changing run detail token presentation.
- Removing completed counts from project/issue/execution-mode/failure/event breakdowns unless those tables have their own redundant columns.

## Acceptance Criteria

- Analytics `Total tokens` is non-zero for persisted Codex events containing real runtime token payload shapes.
- Analytics token parsing matches the shapes accepted by runtime Codex token accounting.
- Repeated cumulative token snapshots do not inflate totals incorrectly.
- Existing simple `payload["tokens"]` fixtures still work.
- The Status breakdown table no longer displays a `Completed` column.
- Other breakdown tables still display status-count columns where useful.
- Rendered Analytics tests prove the Status table is simpler and token totals render from realistic persisted event payloads.
- Empty analytics ranges still render stable zero values.

## Test Cases

- Analytics unit test with event payload:
  - `%{"params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}}}}`;
  - assert total tokens are `15`.
- Analytics unit test with wrapper payload:
  - `%{"params" => %{"msg" => %{"payload" => %{"info" => %{"total_token_usage" => ...}}}}}`;
  - assert tokens are extracted.
- Analytics unit test with repeated cumulative snapshots for the same run:
  - first total `10`;
  - second total `15`;
  - assert final contribution is `15`, not `25`, if using per-run maximum cumulative semantics.
- Analytics unit test with two separate runs:
  - assert totals aggregate across runs.
- LiveView test:
  - persisted realistic Codex token event renders non-zero `Total tokens`.
- LiveView test:
  - Status breakdown table does not include `Completed` header.
- LiveView test:
  - Projects or Issues breakdown still includes `Completed`, `Failed`, and `Blocked` headers.

## Implementation Notes

- Inspect `SymphonyElixir.Codex.Update` before writing a new parser. It already knows how to find token usage in real Codex events.
- If the existing parser is private and too coupled to live running entries, extract a small shared module such as `SymphonyElixir.Codex.TokenUsage` that both `Codex.Update` and `Analytics` can call.
- Be explicit about cumulative vs delta semantics:
  - runtime live accounting computes deltas from monotonic cumulative snapshots;
  - analytics lacks in-memory previous values unless it groups by run/session.
- For historical analytics, grouping token-bearing events by `run_id` and taking the maximum cumulative total per run is safer than summing every cumulative snapshot.
- If an event has no run id, fall back to summing recognized standalone token payloads, but document the lower confidence.
- Update `AnalyticsLive.breakdown/1` to support a table variant or option, for example `status?`, `show_status_columns?`, or a dedicated status breakdown component.
- Avoid string-based HTML assertions that are too broad. Test for the status table header structure or rendered section-specific content.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/token_usage_test.exs test/symphony_elixir/codex_update_test.exs test/symphony_elixir/analytics_test.exs test/symphony_elixir_web/analytics_live_test.exs`
- `mise exec -- mix test --cover`
  - Result: 620 tests, 0 failures, 2 skipped.
- `mise exec -- mix exec_plans.check`
- Rendered LiveView assertions cover `/analytics` with realistic persisted Codex token payloads and verify the Status table header is `Name`, `Runs` while project breakdowns retain status columns.

## Completion Deviations

None.

## Dependencies

- Completed plan 158 for the Analytics page.
- Completed plan 127 for Codex update boundary.
- Completed plan 156 for known rate-limit payload rendering, which established realistic Codex payload handling expectations.
- Completed plan 180 for observability test split.

## Handoff Notes

Do not fix this by inventing token totals from run counts. Analytics should either extract real persisted token usage accurately or show zero honestly. The target is to reuse the same token-shape knowledge as runtime accounting so Dashboard and Analytics stop disagreeing.
