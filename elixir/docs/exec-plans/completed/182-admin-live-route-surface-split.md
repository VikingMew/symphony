# 182 Admin Live Route Surface Split

## Goal

Split `AdminLive` route surfaces so settings, observability, workers, and import pages no longer share one 2,000+ line LiveView.

## Status

Completed.

## Background

Several helper extractions have reduced `AdminLive`, but `lib/symphony_elixir_web/live/admin_live.ex` remains over 2,000 lines. It still owns routing/rendering for many surfaces:

- settings project/workflow/agents/runtime/import pages;
- runs list and run detail;
- issue detail;
- events;
- workers;
- import notices and runtime mismatch summaries.

Helper extraction helps, but the route surface itself remains too broad. The remaining problem is ownership: unrelated product pages still share one LiveView process and render function.

## Scope

- Inventory `@live_action` branches and route ownership.
- Choose one route family to split first, preferably observability pages or workers because settings has its own ongoing complexity.
- Move the selected route family into a new LiveView module while preserving routes and URLs if possible.
- Keep shared presenters/components shared rather than copied.
- Add route/render tests for the moved family.

## Out of Scope

- Redesigning the UI.
- Changing URLs unless a route-level migration is explicitly chosen.
- Moving all route families in one change.
- Changing persistence behavior.

## Acceptance Criteria

- One coherent route family leaves `AdminLive`.
- `AdminLive` line count drops for a real ownership reason, not by moving random helpers.
- Shared presenters/components remain reusable.
- Existing route tests still pass and URL behavior is preserved.

## Verification

- `mise exec -- mix test test/symphony_elixir_web/live/observability_fake_persistence_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `/workers` now routes through `SymphonyElixirWeb.WorkersLive`.
- `rg -n "live_action|runs|events|workers|settings|diagnostics" lib/symphony_elixir_web/live/admin_live.ex lib/symphony_elixir_web/live test`
- `wc -l lib/symphony_elixir_web/live/admin_live.ex`
- `mix exec_plans.check`

## Completion Deviations

The workers route family was split first; settings/runs/events remain in `AdminLive` for later route-level extractions.
