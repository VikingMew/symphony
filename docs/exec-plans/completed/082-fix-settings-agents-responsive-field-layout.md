# 082 Fix Settings Agents Responsive Field Layout

## Goal

Fix the remaining `/settings/agents` layout failures shown in the screenshots. The page must be usable in the actual browser at the user's current narrow width, not just pass HTML class assertions or look acceptable in one full desktop screenshot.

## Context

Plan 081 improved the intended page structure, but the screenshots still show the real rendered page breaking:

- Base Prompt textarea is still a narrow floating box.
- The "Base prompt" label appears beside or below the textarea instead of above it.
- Profile fields still behave like inline rows:
  - `Executor` label sits left of the select.
  - `Prompt mode`, `Profile prompt template`, and the prompt textarea collide in one row.
  - `Allowed target states` label sits left of its textarea.
- The layout wastes horizontal space while simultaneously squeezing controls.
- The visible browser width is narrow enough that any two-column/profile-grid layout must collapse reliably.

The likely root issue is that generic label/form CSS or grid child rules still allow some field labels to participate as inline text at narrow widths, and the prior tests only asserted class names. That is not enough. This plan must verify real computed layout.

## Scope

- Rework `/settings/agents` field markup and CSS so every editor field uses an explicit vertical field component.
- Add strong, scoped CSS for the Agents tab:
  - all field wrappers are block/grid containers,
  - labels are always above controls,
  - textareas and selects are full-width within their group,
  - profile prompt and target states never share a row with their labels,
  - profile internals collapse to one column before the screenshot width.
- Replace any layout that depends on `label` as both wrapper and grid item if it keeps producing ambiguous browser behavior.
- Tune responsive breakpoints for the width shown in the screenshots, not only mobile and wide desktop.
- Keep the improved 081 hierarchy:
  - Base Prompt,
  - Profiles,
  - profile header,
  - Identity,
  - Execution,
  - Prompt,
  - Updates,
  - Routing.
- Preserve save, validation, and persistence behavior.

## Non-Goals

- Do not change workflow/profile schema.
- Do not change save semantics.
- Do not redesign Workflow or Runtime tabs except for shared CSS necessary to avoid regressions.
- Do not hide fields to make layout easier.
- Do not rely on browser cache clearing as the fix. The CSS and markup must be robust when loaded fresh.

## Acceptance Criteria

- [x] At the screenshot-like narrow width, Base Prompt label is above the textarea.
- [x] At the screenshot-like narrow width, Base Prompt textarea spans the available content width instead of rendering as a narrow floating box.
- [x] At the screenshot-like narrow width, `Name`, `Executor`, `Prompt mode`, `Profile prompt template`, and `Allowed target states` labels are each above their controls.
- [x] At the screenshot-like narrow width, Profile prompt template textarea starts on its own row and does not sit beside `Prompt mode`.
- [x] At the screenshot-like narrow width, Allowed target states textarea starts below its label and does not sit beside it.
- [x] At the screenshot-like narrow width, no profile section has horizontal overflow.
- [x] At 1365px desktop width, profile sections remain readable and do not create a huge empty right side for Base Prompt.
- [x] At 390px mobile width, there is no document-level horizontal overflow.
- [x] Save button, `phx-disable-with`, validation error, and saved/error toast still render and work.

## Test Plan

- Keep existing LiveView structural assertions for `/settings/agents`.
- Add browser-level verification using Playwright with the installed Chrome executable:
  - screenshot-like viewport matching the user's screenshots, approximately `570x810`,
  - desktop viewport `1365x768`,
  - mobile viewport `390x844`.
- For each browser viewport, evaluate DOM geometry:
  - field label bottom must be above the corresponding input/textarea top,
  - field control width must be close to its field wrapper width,
  - `document.documentElement.scrollWidth <= document.documentElement.clientWidth`.
- Save screenshots to `/tmp` during verification for manual inspection if needed.
- Run:
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Prefer explicit markup:
  - `<div class="agent-field">`
  - `<label class="agent-field-label" for="...">`
  - control element after the label
  instead of wrapping every control in a `<label>` if wrapper labels continue to render unpredictably.
- Scope the stronger rules under an Agents-specific class such as `.agent-settings-form` so Workflow tab styling is not destabilized.
- Use `grid-template-columns: minmax(0, 1fr)` at narrow and medium widths; only allow two columns at widths where there is enough room.
- Consider making the Prompt group always single-column because a prompt mode select plus a large textarea is semantically vertical.
- The browser verification is part of the definition of done; do not mark the plan complete based only on unit tests or class-name checks.
