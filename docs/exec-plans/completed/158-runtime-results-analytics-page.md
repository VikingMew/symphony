# 158 Runtime Results Analytics Page

## Goal

Persist runtime execution results in the database and add a dedicated top-level Analytics page where operators can inspect runtime, agent, and project progress metrics for a selected time range.

The page should answer operational questions such as:

- How much work did agents complete in the selected period?
- Which projects/issues moved forward, stalled, failed, retried, or blocked?
- How long did runs take?
- Which profiles/states consume the most time or fail most often?
- What are current and historical agent throughput, success, failure, retry, and blocked rates?

## Status

Completed.

## Background

Symphony currently has several operational surfaces:

- Dashboard for current running/retrying/blocked state.
- Runs and run detail pages for individual persisted runs.
- Events for raw audit/debugging.
- Linear diagnostics for tracker health.

Those views are useful for live operations and per-run debugging, but they do not provide a database-backed historical analytics view. Operators need a way to choose a time range and understand overall runtime outcomes: agent progress, project progress, throughput, failures, retry behavior, blocked sessions, duration distribution, token usage, and state movement.

Some runtime data is already persisted in runs/events/agent turns/workflow versions. Other currently in-memory or derived runtime results may need to be normalized into durable tables or summary records. The analytics page should read from database-backed data, not from transient GenServer state.

## Scope

- Define the durable runtime result data needed for analytics.
- Persist or normalize runtime execution outcomes into database-backed records:
  - run lifecycle status and timestamps;
  - issue/project identifiers;
  - workflow version/profile/state context;
  - worker host/execution mode;
  - retry/attempt information;
  - blocked/input-required state when applicable;
  - failure class/reason;
  - token totals and runtime duration;
  - key agent summary fields when available.
- Add a top-level navigation tab/page, for example `/analytics` labelled `Analytics` or `Stats`.
- Support time-range selection:
  - preset ranges such as last 24h, 7d, 30d;
  - custom start/end datetime where practical.
- Show metrics grouped by:
  - overall runtime;
  - project;
  - workflow profile/phase;
  - Linear state/status;
  - issue;
  - worker/execution mode when available.
- Include agent progress and project progress views:
  - completed/failed/stopped/blocked run counts;
  - active vs terminal issue movement;
  - average and percentile duration;
  - retry counts and retry rate;
  - blocked session counts;
  - token usage totals;
  - throughput over time.
- Add links from aggregate rows to filtered Runs/Events/Issues pages.
- Add tests for aggregation correctness and rendered page behavior.

## Out of Scope

- Do not build a full BI/reporting system.
- Do not require external analytics infrastructure.
- Do not call Linear live for historical analytics unless a separate cache/snapshot already exists.
- Do not store unbounded raw Codex transcripts for analytics.
- Do not replace the current dashboard or run detail pages.
- Do not add complex charting dependencies unless the existing frontend stack already supports them cleanly.

## Acceptance Criteria

- Runtime results needed for analytics are stored in the database or derived from persisted database records.
- Analytics is a first-class top-level navigation entry.
- Operators can select a time range.
- The page shows overall run counts by status for the selected range.
- The page shows agent progress metrics, including completed, failed, stopped, retrying/retried, and blocked counts when data exists.
- The page shows project progress metrics by project/issue group when project data exists.
- The page shows duration and token usage summaries.
- Aggregate rows link to relevant filtered detail pages.
- The page does not depend on live in-memory orchestrator state for historical results.
- Tests cover aggregation from realistic persisted run/event fixtures.

## Test Cases

- Empty database/time range:
  - analytics page renders clear empty state;
  - no crashes.
- Runs across statuses:
  - completed, failed, stopped, blocked, and retry records aggregate into correct counts.
- Time range filtering:
  - records outside selected range are excluded;
  - boundary timestamps are handled consistently.
- Project grouping:
  - runs tied to different projects aggregate separately.
- Profile/state grouping:
  - runs with workflow/profile/state metadata aggregate by profile/phase.
- Token/duration metrics:
  - totals and averages are computed from persisted records.
- Link behavior:
  - clicking a project/status aggregate links to a filtered runs/events/issues view.
- Historical-only mode:
  - analytics renders correctly without relying on current orchestrator snapshot.

## Implementation Notes

Start with a clear analytics read model. Avoid making the LiveView issue ad hoc queries directly against many persistence tables.

Possible module boundaries:

```elixir
SymphonyElixir.Analytics
SymphonyElixir.Analytics.Query
SymphonyElixir.Analytics.RuntimeResult
SymphonyElixirWeb.AnalyticsLive
```

Prefer deriving metrics from persisted canonical records first:

- `runs`;
- `events`;
- `agent_turns`;
- workflow versions;
- project records;
- worker tasks/leases where relevant.

If current run records do not contain enough fields for project/profile/state analytics, add normalized nullable columns or a companion runtime-results table. Do not encode all analytics only as raw event payload scans if the values are first-class query dimensions.

Keep time handling explicit:

- store/query UTC timestamps;
- render in a consistent format;
- make range boundaries deterministic in tests.

For charts, start with dense tables and simple sparkline/bar UI only if available in the existing design. The first version should prioritize correctness and drill-down links over visual complexity.

## Verification

- `mise exec -- mix format`
- Focused analytics aggregation tests.
- Focused persistence/read-model tests for runtime results.
- Focused LiveView/rendered tests for `/analytics` with realistic fixtures.
- Existing run/events/dashboard tests.
- Browser or rendered LiveView evidence for:
  - empty state;
  - populated 7-day range;
  - project/profile breakdown;
  - drill-down links.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

Implemented the first analytics read model by deriving metrics from persisted runs, events, and projects instead of adding a companion summary table. Profile/state analytics remain limited to fields already persisted by run and event records.

## Dependencies

- Completed plan 062 for run detail observability pages.
- Completed plan 103 for run-scoped event history.
- Completed plan 108 for run finished-at persistence.
- Completed plan 118 for Codex history signal persistence.
- Completed plan 141 for run-level execution summary.
- Existing persistence/runtime records.

## Handoff Notes

This is a historical analytics feature, not a live dashboard replacement. The durable database read model is the foundation; the UI should be a thin, testable presentation over time-range queries.
