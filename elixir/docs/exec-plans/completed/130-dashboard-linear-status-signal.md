# 130 Dashboard Linear Status Signal

## Goal

Add a compact Linear status signal to the main dashboard that tells operators whether the active Linear integration appears healthy, degraded, or unknown, and lets them click through to the existing Linear diagnostics page.

## Status

Completed.

## Background

Symphony already has a dedicated Linear diagnostics page at `/diagnostics/linear`. Completed plan 022 added the page and completed plan 024 improved its diagnostic log, refresh visibility, runtime source context, and workflow-change guidance.

The main dashboard still lacks a small always-visible signal for Linear health. Operators can see run counts, token totals, runtime, and rate-limit information, but they cannot quickly tell whether Symphony is currently able to see Linear, whether the configured project is valid, whether workflow states match Linear, or whether candidate issue discovery is failing. They must know to open the Linear page proactively.

The dashboard should not duplicate the full diagnostics page. It should provide a concise status chip/card and a direct navigation path to `/diagnostics/linear`.

## Scope

- Add a compact Linear status signal to the dashboard first viewport or near the existing operational metric cards.
- The signal should summarize the active Linear diagnostics state with one of a small set of statuses:
  - `ok`: Linear diagnostics recently passed enough probes for runtime polling to be trusted.
  - `warning`: Linear is configured but has partial issues, such as missing workflow states or no current candidate issues.
  - `error`: Linear token, API, project, or state probes failed.
  - `unknown`: diagnostics have not been run or no fresh diagnostic snapshot is available.
- Make the signal clickable, linking to `/diagnostics/linear`.
- Include concise supporting text:
  - last diagnostics run time when known;
  - failing probe name or primary issue when known;
  - configured Linear project slug when available;
  - candidate issue count when available.
- Reuse the existing Linear diagnostics backend/result shape where possible.
- Avoid expensive Linear API calls on every dashboard refresh if the current diagnostics path is intentionally manual.
- Add tests that prove the dashboard signal renders and links to the Linear page.

## Out of Scope

- Do not duplicate the full Linear diagnostics table on the dashboard.
- Do not automatically mutate Linear issues or statuses.
- Do not expose the Linear API token or secret-bearing headers.
- Do not add a new Linear configuration editor to the dashboard.
- Do not make dashboard refresh perform expensive GraphQL probes unless there is a bounded/cache-aware design.
- Do not remove the existing top-level `Linear` navigation item.

## Acceptance Criteria

- The dashboard shows a Linear status signal without requiring the user to open `/diagnostics/linear` first.
- The signal links to `/diagnostics/linear`.
- The signal uses clear visual severity:
  - success for healthy;
  - warning for partial/unknown-but-configured states;
  - danger/error for failed diagnostics;
  - neutral/info for not yet run.
- The signal never renders Linear API tokens or Authorization headers.
- If diagnostics have never run, the signal says so and prompts the operator to open Linear diagnostics.
- If diagnostics show a token/API/project/state failure, the signal shows the primary failing area.
- If diagnostics show candidate issues, the signal can show a count without listing every issue.
- Existing dashboard metrics remain visible and are not crowded out.

## Test Cases

- Dashboard with no diagnostics snapshot:
  - renders `Linear unknown` or equivalent;
  - links to `/diagnostics/linear`.
- Dashboard with healthy diagnostics:
  - renders a success state;
  - shows last run time and project slug when available.
- Dashboard with missing token/API failure:
  - renders an error state;
  - does not render the token value.
- Dashboard with missing workflow states:
  - renders warning or error according to the chosen severity policy;
  - shows the missing-state summary in bounded form.
- Dashboard with candidate issues:
  - renders candidate count only, not a large issue list.
- Existing `/diagnostics/linear` tests continue to pass.

## Implementation Notes

Prefer adding a small presenter/helper boundary rather than having the dashboard LiveView inspect the full diagnostics map directly.

Possible data flow:

1. Keep `/diagnostics/linear` as the canonical detailed page.
2. Add a lightweight `LinearStatusSignal` presenter that accepts the latest diagnostics result or a cached summary.
3. Have the dashboard render the summary as a compact card/chip linking to `/diagnostics/linear`.

Important design choice: decide where the "latest diagnostics" comes from.

- If diagnostics are currently only computed on page mount/refresh and not persisted, use an `unknown` signal by default and make it a clear call-to-action.
- If a safe in-memory or persisted diagnostics summary exists, reuse it.
- If adding cache/persistence, keep it bounded and store only sanitized probe statuses, timestamps, project slug, candidate count, and primary messages.

Do not make the dashboard perform full Linear diagnostics on every LiveView refresh without a throttle/cache. Dashboard refresh can be frequent, and Linear diagnostics may involve multiple GraphQL calls.

The signal should use existing UI patterns: `metric-card`, `status-badge`, `section-card`, and existing navigation link styles.

## Verification

- `mise exec -- mix test test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test --cover` passed with 424 tests, 0 failures, 2 skipped, 85.54% total coverage.
- Rendered dashboard assertions prove the `Linear unknown` signal appears and links to `/diagnostics/linear`.
- `SymphonyElixirWeb.LinearStatusSignal` tests cover unknown, healthy, and error summaries without running Linear GraphQL from the dashboard.

## Completion Deviations

No persistent diagnostics cache was added. The dashboard intentionally renders an `unknown` signal by default and links to the canonical diagnostics page, while the presenter supports healthy/error summaries for future cached diagnostics reuse.

## Dependencies

- Completed plan 022 for `/diagnostics/linear`.
- Completed plan 024 for richer Linear diagnostics visibility.
- Existing dashboard LiveView and navigation components.

## Handoff Notes

Keep this as a dashboard signal, not a second diagnostics page. The dashboard should answer "is Linear probably okay right now?" and provide a fast path to the full Linear page for details and refresh actions.
