# 077 Settings Tabs Consolidation

## Goal

Consolidate the three current settings/configuration surfaces into one top-level Settings area with three real tabs. The page must not become one long stacked settings page: only the selected tab's content should be visible and active.

## Context

The current UI has separate top-level entry points for workflow configuration, agent/profile settings, and general settings. This makes configuration feel fragmented and also makes the navigation imply that these are independent product areas.

The intended product model is one Settings page with separate tabbed sections:

- Workflow
- Agents
- Runtime

The tab structure should make the relationship clear without mixing all forms into one long page.

## Scope

- Replace the top-level navigation entries for workflow and agent settings with a single Settings entry.
- Make `/settings` the single settings entry point.
- Add canonical tab routes:
  - `/settings/workflow`
  - `/settings/agents`
  - `/settings/runtime`
- Make `/settings` open the default Workflow tab.
- Remove old `/workflows` and `/agent-settings` routes instead of keeping redirects.
- Render a tab bar at the top of the Settings page.
- Render only the active tab body:
  - Workflow tab: current workflow/routing configuration.
  - Agents tab: profile/base-prompt configuration.
  - Runtime tab: existing runtime/general settings content.
- Preserve existing save, saving, saved, and error feedback behavior inside the relevant tab.
- Update tests and user-facing docs so Settings is described as one page with three tabs.

## Non-Goals

- Do not redesign the internal workflow form beyond moving it into the Workflow tab.
- Do not add new persistence concepts or schema changes.
- Do not merge all settings into one large form.
- Do not reintroduce workflow file editing or template generation.
- Do not keep workflow or agent settings as first-class top-level navigation pages.

## Acceptance Criteria

- [x] The top navigation shows one Settings entry for these configuration areas.
- [x] `/settings` opens the Workflow tab.
- [x] `/settings/workflow` shows the workflow configuration and does not show agent profile panels or runtime settings as stacked sections.
- [x] `/settings/agents` shows profile/base-prompt configuration and does not show the workflow form or runtime settings as stacked sections.
- [x] `/settings/runtime` shows the general runtime/settings content and does not show workflow or agent configuration as stacked sections.
- [x] `/workflows` is not a configured route.
- [x] `/agent-settings` is not a configured route.
- [x] Save behavior still works from the Workflow tab.
- [x] Save behavior still works from the Agents tab.
- [x] Tests assert that inactive tab content is not rendered on each tab route.

## Test Plan

- Add or update LiveView tests for:
  - `/settings`
  - `/settings/workflow`
  - `/settings/agents`
  - `/settings/runtime`
- Add route assertions that `/workflows` and `/agent-settings` are no longer configured.
- Add navigation assertions that workflow and agent settings are no longer separate top-level nav entries.
- Add tab isolation assertions so each route renders only its active tab content.
- Run:
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Prefer route/action-driven tabs over a client-only tab switch so each tab is bookmarkable.
- Keep the current workflow/profile draft assigns where possible; the change is layout and routing, not data ownership.
- Extract tab body rendering into small helpers if the LiveView template becomes hard to read.
- Style the tab bar as part of the Settings page header, not as separate cards.
- Keep responsive behavior simple: the tab list may scroll horizontally on narrow screens, but the tab bodies should remain stable and fixed-width where existing textbox rules require it.
