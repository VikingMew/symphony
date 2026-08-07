# 166 Admin Live Observability Page Boundary

## Goal

Separate run, issue, worker, and events observability page derivation from settings-page logic inside `AdminLive`.

## Status

Completed.

## Background

`AdminLive` now acts as the owner for multiple unrelated web surfaces:

- settings pages;
- runs list and run detail;
- issue detail;
- events page;
- workers page;
- import notices and workflow runtime summaries.

Some shared rendering is acceptable, but the current module still contains observability-page payload formatting, event payload scrubbing, duration formatting, status classes, worker empty messages, labels formatting, and workflow-version summaries near settings helpers.

This creates review friction and makes future analytics/results work more likely to edit the same file as settings changes.

## Scope

- Extract observability page presenter functions into a focused module.
- Move safe payload scrubbing, status class mapping, duration formatting, worker empty messages, and run/workflow summary formatting out of `AdminLive`.
- Keep route handling and persistence calls in the LiveView unless a later plan splits LiveViews by route.
- Preserve existing HTML semantics and CSS classes.

## Out of Scope

- Adding the analytics page from plan 158.
- Splitting Phoenix routes.
- Changing event retention or run persistence.
- Rewriting settings pages.

## Acceptance Criteria

- Observability page formatting is tested without mounting `AdminLive`.
- `AdminLive` has fewer unrelated private helpers at the bottom of the file.
- Existing run detail, issue detail, events, and workers tests still pass.
- Plan 158 can build on a cleaner observability presenter instead of adding more logic to `AdminLive`.

## Verification

- Focused tests for the new observability presenter
- `mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `rg -n "fmt_duration|safe_event_payload|scrub_payload|status_class|worker_empty_message|workflow_version_summary|labels_text" lib test`
- `mix exec_plans.check`

## Completion Deviations

Extracted AdminLive observability presentation helpers into `SymphonyElixirWeb.Admin.ObservabilityPresenter`; LiveView route handling and persistence reads remain in `AdminLive`.
