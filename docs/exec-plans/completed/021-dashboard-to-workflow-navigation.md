# Task 021: Dashboard to Workflow Settings Navigation

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 005, Task 016, Task 018, Task 020
**Created**: 2026-05-01

## Goal

Make workflow configuration discoverable from the logged-in dashboard by adding a clear, authenticated navigation path from the main dashboard to `/workflows`.

## Background

The service can now start in port/dashboard mode, authenticate successfully, and render the dashboard. The workflow settings page already exists at `/workflows`, and the admin pages have internal navigation links, but the first page an operator sees after login is `DashboardLive`. That dashboard currently has no visible path to workflow settings.

This creates a broken first-run experience: a user can log in and see the dashboard, but cannot discover where to create or edit the database-backed workflow without knowing the URL manually. This is especially harmful in no-file port mode, where workflow setup is the next required action.

## Scope

- Add a top-level dashboard navigation surface that links to workflow settings.
- Include at minimum links for Dashboard, Workflows, Runs, Workers, Projects, and Settings so the main dashboard and admin pages feel like one web UI.
- Make `/workflows` especially discoverable when no active workflow is configured.
- Preserve existing auth behavior for all navigation targets.
- Keep visual treatment consistent with the dashboard color system from Task 016.
- Add tests that verify a logged-in user can discover and follow the workflow settings link from `/`.

## Out of Scope

- Redesigning the full dashboard layout.
- Building a structured workflow field editor beyond the existing raw `WORKFLOW.md` editor.
- Changing workflow source precedence rules.
- Adding project-specific workflow selection.
- Adding unauthenticated access to workflow settings.

## Acceptance Criteria

- [x] The main dashboard page renders a visible link or button to `/workflows`.
- [x] The navigation is available after login without typing `/workflows` manually.
- [x] The navigation does not disappear when the dashboard snapshot is unavailable.
- [x] If no active workflow exists, the dashboard shows an actionable setup affordance that points to `/workflows`.
- [x] Admin pages and dashboard pages use a consistent navigation vocabulary and ordering.
- [x] Existing auth tests continue to prove `/workflows` is protected.
- [x] A LiveView or controller test covers dashboard-to-workflow discovery.

## Test Cases

- Log in, visit `/`, assert the response includes a workflow settings link.
- Follow the workflow settings link and assert `/workflows` renders the raw workflow editor or setup state.
- Simulate snapshot unavailable on `/` and assert the workflow settings link is still present.
- Start with no active DB workflow in port mode and assert the dashboard has a setup call-to-action linking to `/workflows`.
- Attempt `/workflows` without authentication and verify redirect/login protection remains unchanged.

## Implementation Notes

- Prefer a small reusable app navigation component or helper if it avoids duplicating the same nav markup between `DashboardLive` and `AdminLive`.
- If a shared component is added, keep it simple and local to the web layer; do not introduce a broader design-system abstraction for this task.
- The link label should be operator-facing and direct, for example `Workflows` or `Workflow Settings`.
- The no-workflow setup affordance should be displayed in a stable location near the top of the dashboard, not hidden below runtime tables.
- Avoid adding in-app explanatory prose about implementation details; focus on actionable navigation.
- Use the existing `section-card`, `issue-link`, `subtle-button`, or matching dashboard CSS classes unless a small new class is needed for layout.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix lint`
- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix test test/symphony_elixir/*web*_test.exs`
- Manual check: log in, open `http://127.0.0.1:4000/`, click workflow settings, confirm `/workflows` renders.

## Completion Deviations

- Implemented the navigation as a shared function component in `SymphonyElixirWeb.Layouts`.
- Added the setup affordance only when the configured workflow source requires database setup and no usable fallback file exists.
- Kept the existing raw workflow editor unchanged.

## Dependencies

- Workflow management UI from Task 005.
- Dashboard color system from Task 016.
- First workflow setup state from Task 018.
- Port-mode no-file startup and docs from Task 020.

## Handoff Notes

- Record whether navigation is implemented as shared markup, a function component, or duplicated minimal links.
- Record the exact label used for the workflow settings entry.
- Record whether the no-workflow setup affordance required any presenter or workflow-store changes.

Navigation is implemented as a shared `app_nav/1` function component. The workflow settings entry is labeled `Workflows`. The no-workflow setup affordance is computed locally in `DashboardLive` and did not require presenter or workflow-store changes.
