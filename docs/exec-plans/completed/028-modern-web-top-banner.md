# Task 028: Modern Web Top Banner

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 016, 021, 027
**Created**: 2026-05-05
**Completed**: 2026-05-05

## Goal

Replace the current row of plain navigation words with a modern Web application top banner.

The banner should feel like an application shell header: clear brand identity, predictable primary navigation, visible current page state, and responsive behavior that remains usable on narrow screens.

## Background

The Web UI already has useful pages for dashboard, workflows, runs, workers, Linear diagnostics, projects, and settings. Navigation exists, but it reads like several text links placed next to each other rather than a real product header.

This task improves the shared navigation surface only. It should not redesign every page, change runtime logging, or introduce a frontend build pipeline.

## Scope

- Update the shared `SymphonyElixirWeb.Layouts.app_nav/1` component.
- Present a top banner with:
  - a compact Symphony brand mark and name;
  - a short product/context label;
  - primary navigation links;
  - a clear active page state;
  - responsive horizontal navigation on small screens.
- Keep the banner shared by Dashboard, Workflows, Runs, Workers, Linear, Projects, and Settings.
- Update `/dashboard.css` styles for the banner.
- Keep existing page content and routes intact.
- Add lightweight rendering coverage so the banner is not accidentally reduced back to plain loose links.

## Out of Scope

- Adding a SPA, JavaScript navigation framework, Tailwind, or asset build step.
- Reworking page hero cards, tables, forms, or data models.
- Adding icon dependencies.
- Adding authentication menu behavior.
- Changing terminal logging or runtime status output.
- Changing database initialization behavior.

## Acceptance Criteria

- [x] The top navigation renders as a single application banner, not just adjacent text links.
- [x] The banner includes visible Symphony branding.
- [x] The banner includes a compact product/context label.
- [x] Primary navigation links remain available for all existing pages.
- [x] The current page is visually and semantically marked with `aria-current="page"`.
- [x] The banner is responsive and remains usable on narrow screens.
- [x] Dashboard and admin pages still render their existing main content.
- [x] No frontend build pipeline is introduced.

## Test Cases

- Render `/` and assert the shared banner, brand, context label, Dashboard active state, and Workflows link are present.
- Render `/workflows` and assert the same banner exists while Workflows is the active page.
- Keep existing route/render tests for Dashboard, Workflows, and Linear diagnostics passing.

## Implementation Notes

- Reuse the existing `app_nav/1` component so call sites stay simple.
- Use semantic HTML: a banner/header containing navigation with `aria-label="Primary"`.
- Prefer CSS for the compact brand mark rather than adding a new asset.
- Keep card radius at 8px or less for banner controls; the top banner should feel like app chrome, not a decorative card.
- Preserve the existing constrained application width from `.app-shell`.
- Avoid changing page-specific hero copy or metric layouts.

## Verification

- [x] `mise exec -- mix format --check-formatted`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix build`

## Completion Deviations

None.

## Dependencies

- Task 016 dashboard color system, for visual consistency.
- Task 021 navigation consistency, because this task upgrades the shared navigation.
- Task 027 normal logger output, to keep this work scoped to the Web header and not terminal logging.

## Handoff Notes

- The banner remains server-rendered Phoenix/LiveView markup with static CSS.
- Future account controls or environment indicators can be added to the right side of the banner without changing page-level LiveViews.
