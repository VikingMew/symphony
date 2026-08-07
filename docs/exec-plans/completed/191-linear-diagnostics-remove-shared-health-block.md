# 191 Linear Diagnostics Remove Shared Health Block

## Goal

Remove the `Shared health` block from the Linear diagnostics page because it exposes internal runtime/cache mechanics instead of answering the operator's Linear configuration question.

The Linear page should show actionable diagnostics: connectivity, project resolution, workflow state compatibility, candidate issue discovery, and repair actions. It should not ask users to understand how Symphony internally shares Linear health observations between pages.

## Status

Completed.

## Background

The Linear diagnostics page currently renders a metric card labelled `Shared health` above the concrete diagnostic probes. That card is backed by `SymphonyElixir.Linear.Health.latest/0`, a shared sanitized health summary introduced so the Dashboard and Linear page could agree about the latest known Linear status.

The shared health boundary is still useful internally, especially for the Dashboard Linear signal. The problem is presentation: on the Linear diagnostics page, the card is redundant and often confusing because the page itself already runs diagnostics and renders the concrete probe results. Showing a separate "shared" signal makes operators ask whether it is a second source of truth, a cache, a freshness marker, or an execution detail.

The user-facing contract should be simpler:

- Dashboard may show a compact Linear signal derived from shared health.
- Linear diagnostics should show the latest diagnostics run and probe details.
- The user does not need to know how Symphony stores or propagates shared health observations.

## Scope

- Remove the `Shared health` metric card from `SymphonyElixirWeb.LinearDiagnosticsLive`.
- Remove helper functions that become presentation-only dead code after the block is removed, such as Linear-page-only health label/detail formatting.
- Keep the underlying `SymphonyElixir.Linear.Health` module and shared health updates intact for Dashboard and other consumers.
- Keep Linear diagnostics refresh behavior intact.
- Ensure the Linear diagnostics page still has a clear top summary through:
  - last diagnostics run time;
  - run id;
  - workflow source;
  - concrete probe cards.
- Adjust tests that assert rendered Linear diagnostics content so they no longer expect `Shared health`.
- Add or update a rendered test that asserts the page does not expose the `Shared health` block while still showing the probe cards.
- Update docs only if any user-facing docs mention the Linear page exposing shared health directly.

## Out of Scope

- Removing the shared Linear health cache itself.
- Changing Dashboard Linear signal behavior.
- Changing diagnostics probe execution or classification.
- Changing routine Linear polling health updates.
- Adding a new replacement card for shared health.
- Renaming backend modules or health fields.

## Acceptance Criteria

- The Linear diagnostics page no longer renders a `Shared health` block/card.
- The page still renders useful diagnostics summary content: last run, run id, workflow source, and probe cards.
- Refreshing diagnostics still updates the diagnostics run and preserves Dashboard health behavior.
- Dashboard Linear signal still consumes shared health and remains covered by existing tests.
- No user-facing copy on the Linear diagnostics page mentions "shared health", internal health cache, or how Symphony propagates Linear observations.
- Dead presentation helpers in `LinearDiagnosticsLive` are removed or kept only if still used by visible diagnostics.

## Test Cases

- Render Linear diagnostics with a healthy shared health cache and successful diagnostics:
  - page does not include `Shared health`;
  - page includes `Last run`;
  - page includes `Run ID`;
  - page includes workflow source and concrete probe cards.
- Render Linear diagnostics with unknown shared health:
  - page does not include "No shared Linear observation has completed yet.";
  - concrete diagnostics still render normally.
- Trigger diagnostics refresh:
  - refreshed diagnostics are rendered;
  - no shared health block appears after refresh.
- Dashboard signal regression:
  - shared health still feeds `LinearStatusSignal` or equivalent Dashboard presenter tests.

## Implementation Notes

- The visible block currently lives in `SymphonyElixirWeb.LinearDiagnosticsLive` inside the `metric-grid` section as an `<article class="metric-card">` labelled `Shared health`.
- After removing that block, check whether these helpers are still referenced:
  - `health_probe_status/1`;
  - `health_detail/1`.
- If `@linear_health` is only assigned for the removed card in this LiveView, remove the assign from mount/refresh/bootstrap paths. Do not remove health updates performed by diagnostics or runtime requests.
- Keep the rest of the metric grid stable so removing the first card does not make the page look sparse or misordered.
- Prefer testing rendered HTML rather than private helpers.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test test/symphony_elixir/dashboard_signal_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`
- Manual browser check of `/linear` or the Linear diagnostics route:
  - no `Shared health` block;
  - actionable diagnostics are still readable above the fold.

## Completion Deviations

None.

## Dependencies

- Completed plan 130 for Dashboard Linear status signal.
- Completed plan 136 for shared Linear health source consistency.
- Completed plan 138 for Linear health classification boundary.
- Completed plan 154 for Linear diagnostics probe boundary.

## Handoff Notes

Do not solve this by deleting the shared health domain. The issue is not the backend state; it is that the Linear diagnostics page currently exposes an implementation detail. The Dashboard can keep using shared health as a compact signal, while the Linear page should focus on concrete, actionable diagnostic facts.
