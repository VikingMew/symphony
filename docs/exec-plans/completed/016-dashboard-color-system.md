# Task 016: Dashboard Color System

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 007, Task 014 recommended
**Created**: 2026-05-01

## Goal

Implement a consistent dashboard UI color system inspired by the blue, orange, green, and yellow palettes described in the design doc, while keeping Symphony's UI operational, readable, and suitable for long-running admin use.

Design reference: [Dashboard 配色系统设计](../../dashboard_color_system_design.zh-CN.md).

## Background

The current dashboard is moving toward a broader operations surface for projects, runs, workflows, workers, tasks, and configuration. Without a shared UI color system, the app shell, navigation, panels, tables, forms, charts, buttons, status badges, and alerts can drift into inconsistent meanings.

The desired visual direction is inspired by Squirtle blue, Charmander orange, Bulbasaur green, and Pikachu yellow, but the implementation should be a professional control-plane palette. Do not use character artwork, logos, silhouettes, or trademark assets.

## Scope

- Add CSS custom properties for neutral, primary, warning, success, accent, and danger colors.
- Apply the palette to the dashboard app shell, navigation, surfaces, tables, forms, buttons, focus states, and chart series.
- Define shared classes for status badges.
- Define shared button, link, focus, border, and soft background states where needed.
- Map run/task/worker statuses to semantic colors.
- Update existing dashboard/admin LiveView templates to use semantic classes instead of ad hoc colors.
- Ensure centralized deployments and worker-mode pages can share the same status language.
- Document component usage if local patterns are not obvious from CSS.

## Out of Scope

- Adding a separate Node frontend.
- Adding a design system package.
- Using character images or branded assets.
- Large dashboard layout redesign.
- Charting library integration.

## Acceptance Criteria

- [ ] CSS tokens exist for neutral, primary, warning, success, accent, and danger.
- [ ] Dashboard/admin pages use shared UI color classes for shell, navigation, surfaces, tables, forms, buttons, and focus states.
- [ ] Status badges use the same token system but are not the only place the palette appears.
- [ ] Status color mapping is consistent across runs, workers, tasks, projects, and workflows.
- [ ] Yellow/accent is not used for critical error text.
- [ ] Danger/error remains visually distinct from warning/running.
- [ ] UI remains usable in centralized deployments with no workers.
- [ ] No Node project or separate frontend app is introduced.
- [ ] Tests or snapshots cover representative status rendering.

## Test Cases

- Render dashboard with completed, running, queued, failed, cancelled states.
- Render dashboard navigation, panels, tables, form inputs, buttons, and focus states using shared color classes.
- Render worker page with online, offline, idle, active lease states once worker pages exist.
- Render centralized no-worker empty state without warning/error styling.
- Render workflow validation success and failure states.
- Verify auth-protected dashboard routes still render after CSS/template changes.
- Verify no status relies on color alone; text labels remain present.

## Implementation Notes

- Prefer CSS variables in the existing Phoenix assets pipeline.
- Avoid inline styles in HEEx templates.
- Keep cards and panels mostly neutral; use color for navigation anchors, selected states, status markers, badges, buttons, charts, focus rings, and alerts.
- Use `primary` for navigation/selected/info, `warning` for running/retrying, `success` for completed/healthy, `accent` for queued/pending, and `danger` for failed/offline/destructive.
- If a reusable component module already exists, centralize status class mapping there.

## Verification

- `mise exec -- mix test test/symphony_elixir_web/*dashboard*_test.exs`
- `mise exec -- mix test`
- Manual browser check of dashboard/admin pages in desktop and mobile widths.

## Completion Deviations

- Added global CSS tokens for the dashboard UI palette.
- Applied the palette to shell, surfaces, tables, forms, buttons, focus states, and status classes.
- This pass does not perform a large layout redesign or add chart components.

## Dependencies

- Improved dashboard pages from Task 007.
- Worker dashboard pages from Task 014 if worker-specific states are implemented in the same pass.

## Handoff Notes

- Record final CSS token names.
- Record which UI shell/table/form/button classes were introduced.
- Record status-to-color mappings.
- Record any pages intentionally left for a later visual pass.
