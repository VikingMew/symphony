# 136 Dashboard Linear Signal Uses Shared Linear Health

## Goal

Make the Dashboard Linear status signal agree with the system's latest known Linear health state.

If Linear diagnostics or routine Linear runtime requests have established that Linear is ready, the dashboard must not continue to show `unknown` unless the health state is stale, unavailable, or explicitly not shareable.

## Status

Completed.

## Background

Completed plan 130 added a compact Linear signal to the dashboard, but its completion deviations explicitly left out a persistent diagnostics cache:

> No persistent diagnostics cache was added. The dashboard intentionally renders an `unknown` signal by default and links to the canonical diagnostics page, while the presenter supports healthy/error summaries for future cached diagnostics reuse.

In real use, this now creates an inconsistent product state:

- Dashboard shows Linear as `unknown`.
- The Linear diagnostics page shows Linear as ready.

That inconsistency undermines the signal. A dashboard health indicator that says `unknown` while the canonical diagnostics page says `ready` is not actionable; it trains operators to ignore the dashboard.

The correct boundary is not "Dashboard refreshes Linear" or "the Linear page owns refresh." Pages should read state; they should not own the act of refreshing Linear health. Linear health should be produced by backend observation points:

- explicit Linear diagnostics runs;
- routine Linear polling/candidate issue requests;
- other Linear API calls that can safely report success, degraded behavior, or failure.

The dashboard and Linear page should both read a shared sanitized Linear health summary. A page may provide an action that asks the backend to run diagnostics, but the page should not be the source of truth for health.

## Scope

- Add a shared latest Linear health summary that can be read by the dashboard and Linear diagnostics page.
- Populate the summary from backend Linear observation points:
  - explicit diagnostics runs;
  - routine Linear polling/candidate issue fetches;
  - other safe Linear client calls that already occur during normal operation.
- Keep query state and refresh/request state separate:
  - query state is the latest completed health conclusion, such as `ready`, `warning`, `error`, `unknown`, or `stale`;
  - refresh/request state is whether a diagnostics or Linear request is currently running, recently failed, or recently completed.
- Have the dashboard Linear signal use the latest completed health summary instead of defaulting to `unknown` whenever a fresh result exists.
- Include freshness semantics:
  - show `ready`/`ok` when the latest successful Linear health conclusion is fresh;
  - show `stale` or `unknown` when the latest health conclusion is older than the chosen TTL;
  - show `error` or `warning` when the latest health summary contains failed/degraded observations.
- Keep the cached/shared summary sanitized:
  - no Linear API token;
  - no Authorization headers;
  - no raw secret-bearing GraphQL payloads.
- Add a navigation path to `/diagnostics/linear`; do not make dashboard rendering run full diagnostics.
- Add tests proving dashboard and Linear page states stay consistent after diagnostics or routine Linear polling updates the shared health summary.

## Out of Scope

- Do not run full Linear diagnostics on every dashboard tick.
- Do not make any LiveView page the source of truth for Linear health.
- Do not expose Linear API tokens or raw Authorization headers.
- Do not store unbounded diagnostics payloads.
- Do not replace the detailed Linear diagnostics page.
- Do not mutate Linear issues or statuses.
- Do not change workflow state routing semantics.

## Acceptance Criteria

- After Linear diagnostics reports ready, the shared health summary records ready and the dashboard reports ready/ok while the result is fresh.
- After routine Linear polling succeeds, the shared health summary can record healthy Linear connectivity and the dashboard does not remain unknown.
- After Linear diagnostics or routine Linear requests report an error, the dashboard Linear signal reports error with the primary failing area.
- If no Linear observation has ever completed, the dashboard may still show unknown.
- If the latest completed Linear health summary is stale, the dashboard clearly says stale/unknown with the last observation time.
- Dashboard state and Linear page state use the same status classification rules or a shared presenter over the same summary.
- The shared summary never stores or renders Linear token values.
- Tests cover ready, runtime-poll success, error, stale, request-in-progress, request-failed-with-prior-result, and never-run states.

## Test Cases

- No Linear observation completed:
  - dashboard renders `Linear unknown`;
  - link points to `/diagnostics/linear`.
- Diagnostics page runs and returns ready:
  - shared summary is stored;
  - dashboard renders ready/ok;
  - project slug and last-run time are shown when available.
- Routine Linear polling/candidate fetch succeeds:
  - shared health summary is updated from the runtime request;
  - dashboard renders ready/ok or a lower-confidence healthy state;
  - dashboard does not require the diagnostics page to have been opened.
- Diagnostics page runs and returns token/API/project failure:
  - shared summary is stored;
  - dashboard renders error and primary failing probe;
  - token values are not present.
- Routine Linear polling fails after a prior ready result:
  - shared summary records request failure separately from the last completed health conclusion;
  - dashboard shows the prior result with a visible degraded/recent failure note, not a blind unknown.
- Health summary exceeds freshness TTL:
  - dashboard renders stale/unknown with last-run time;
  - dashboard links to Linear diagnostics for investigation.
- Diagnostics or polling updates after stale state:
  - dashboard reflects the updated shared health summary.
- Existing Linear diagnostics page tests continue to pass.

## Implementation Notes

Plan 130 already introduced or referenced a dashboard presenter for Linear status. This plan should complete the missing data-sharing boundary and define which backend observations update it.

Possible approaches:

1. Persist a sanitized Linear health summary in SQLite.
   - Best for page reloads and multi-process visibility.
   - Store only status, observation source, probe/request category, primary message, project slug, candidate count, runtime source, run id/request id, and timestamps.
2. Store a sanitized health summary in an application process/cache.
   - Simpler, but can disappear on restart and may be less reliable across deployments.
3. Recompute a very cheap summary from existing persisted diagnostics/events/runtime observations if such data already exists.
   - Only use this if the existing data is already available and sanitized.

Prefer a small dedicated module such as `LinearHealthSummary` or an extension to the existing diagnostics module. Avoid making `DashboardLive` or `LinearDiagnosticsLive` know raw diagnostics/runtime request internals.

Separate the model into two concepts:

- latest completed health conclusion:
  - `ready`;
  - `warning`;
  - `error`;
  - `unknown`;
  - timestamp;
  - source, such as `diagnostics` or `runtime_poll`;
- current/recent request state:
  - `idle`;
  - `running`;
  - `succeeded`;
  - `failed`;
  - timestamp;
  - safe primary error.

Freshness should be explicit. Pick a conservative TTL and show the last observation timestamp so operators can judge whether `ready` is current enough.

The dashboard and Linear page must remain cheap to render. They should read a cached/persisted summary, not run GraphQL probes during render.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/linear_health_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir/linear_diagnostics_test.exs test/symphony_elixir/extensions_test.exs`
  - `46 tests, 0 failures`
  - Covers never-run, diagnostics-ready, diagnostics-error-with-secret-redaction, runtime-poll success, runtime-poll-failure-with-prior-result, stale health, dashboard status classification, and rendered dashboard/diagnostics consistency.
- `mise exec -- mix test --cover`
  - `438 tests, 0 failures, 2 skipped`
  - total coverage: `85.40%`
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `git diff --check`
- `find docs/exec-plans/active -maxdepth 1 -type f -name '*.md' -print | sort`
  - no active plans remain.

## Completion Deviations

- The delivered shared Linear health summary is an application-process cache, not a SQLite-backed persisted record. This keeps dashboard and diagnostics pages consistent during a running node without storing diagnostics payloads, but the summary intentionally resets to `unknown` after process restart until diagnostics or routine Linear polling observes Linear again.

## Dependencies

- Completed plan 022 for `/diagnostics/linear`.
- Completed plan 024 for diagnostics run metadata and refresh visibility.
- Completed plan 130 for the dashboard Linear status signal.

## Handoff Notes

Treat this as a follow-up to plan 130's completion deviation. `unknown` is acceptable only before any Linear observation completes or after the latest completed health conclusion becomes stale. It is not acceptable when diagnostics or routine Linear polling has produced a fresh ready result.
