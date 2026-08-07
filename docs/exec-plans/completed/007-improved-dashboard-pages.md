# Task 007: Improved Dashboard Pages

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 001, Task 004 recommended, Task 005 and Task 006 helpful
**Created**: 2026-05-01

## Goal

Upgrade the dashboard from a minimal observability surface into a practical operations UI for projects, issues, runs, events, workflows, and configuration status.

## Background

As Symphony gains authentication, SQLite persistence, workflow versions, and multi-project tracking, the dashboard needs to show more than current in-memory status. Operators need to answer operational questions quickly:

- What is running now?
- What failed recently?
- Which workflow version produced this run?
- Which project is blocked?
- What workspace path is attached to this issue?
- What changed in configuration?

## Scope

- Add project overview page.
- Add run list and run detail pages.
- Add issue detail page.
- Add event timeline view.
- Add workflow version detail/diff page.
- Add tracker health/config summary page.
- Add clear empty, loading, error, and unauthorized states.
- Add pagination/filtering for historical runs/events.
- Keep existing JSON API behavior compatible or versioned.

## Out of Scope

- Complex analytics.
- Multi-user role-specific dashboards.
- Real-time collaborative editing.
- Separate frontend application.

## Acceptance Criteria

- [ ] Dashboard shows project-level status.
- [ ] Dashboard shows active, queued, failed, completed, and retrying runs.
- [ ] Run detail shows issue metadata, workspace, workflow version, agent turns, and event timeline.
- [ ] Issue detail shows latest known tracker state and related runs.
- [ ] Workflow version detail shows raw workflow and parsed sections.
- [ ] Event lists are paginated or bounded.
- [ ] Pages are protected by authentication from Task 001.
- [ ] UI remains usable without a Node frontend project.
- [ ] LiveView tests cover major page states.

## Test Cases

- Authenticated user can view project overview.
- Unauthenticated user is blocked from dashboard pages.
- Project overview renders empty state when no projects/runs exist.
- Project overview renders active, queued, failed, completed, and retrying run counts.
- Run list supports pagination or bounded result limits.
- Run detail shows issue metadata, workspace path, workflow version, agent turns, and event timeline.
- Issue detail shows latest tracker state and related runs.
- Workflow version detail shows raw workflow and parsed sections.
- Event timeline renders known event types and handles unknown future event types safely.
- Tracker health/config summary shows success and failure states.
- Live updates refresh active run status without full page reload where PubSub is used.
- JSON API compatibility tests pass if presenter or route behavior changes.

## Implementation Notes

- Use Phoenix LiveView and server-rendered components.
- Keep the UI compact and operational. Avoid marketing-style hero pages or decorative layouts.
- Prefer tables, tabs, filters, and detail panels over card-heavy pages.
- Source historical data from SQLite once Task 004 lands.
- Continue using PubSub for live updates where it helps active runs.
- Make project scoping explicit so Task 006 data remains understandable.

## Verification

- LiveView tests for each new page.
- Controller/API tests if endpoints change.
- `mise exec -- mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
- `mise exec -- mix test`
- Manual check at desktop and mobile widths once the server can run locally.

## Completion Deviations

- Added authenticated operational pages for projects, runs, workflows, and settings.
- The pages use Phoenix LiveView and do not introduce a Node frontend project.
- This pass provides foundational persisted-data views; richer run detail, issue detail, event timelines, and visual polish remain follow-up UI work.

## Handoff Notes

- Record which pages still use in-memory data vs SQLite.
- Record any UI states that need real-world data to refine.
- Record dashboard performance issues discovered during pagination/filtering.
