# 081 User Friendly Settings Layout

## Goal

Make the Settings pages feel like a usable modern operations UI instead of a raw collection of labels and textareas. The immediate priority is the Agents tab shown in the screenshot, but the layout primitives should also improve Workflow and Runtime consistency where they share the same form components.

## Context

The Settings consolidation created the right top-level shape: one Settings area with Workflow, Agents, and Runtime tabs. The current tab body layout is still too close to an unstructured form dump.

Problems visible in `/settings/agents`:

- The Base Prompt textarea is narrow and left-aligned while the rest of the page has a large unused blank area.
- The Base Prompt label can sit below the textarea, which makes the field relationship look broken.
- Profile fields are laid out in a single horizontal flow, so labels, inputs, selects, and prompt textareas collide visually or wrap in awkward places.
- Profile sections do not communicate hierarchy: identity, executor behavior, prompt behavior, update permissions, and target states should read as separate groups.
- Help copy is wordy and consumes vertical space without making the form easier to operate.
- Save state exists, but the primary action is not visually anchored to the editor content.

The fix should make Settings scannable, predictable, and comfortable for repeated editing.

## Scope

- Redesign the Settings tab body layout using existing Phoenix LiveView templates and `dashboard.css`.
- Add Settings-specific layout primitives:
  - a constrained settings body width,
  - a sticky or visually anchored action row for save/status,
  - two-column editor layouts where appropriate,
  - responsive single-column behavior on narrow screens.
- Redesign `/settings/agents`:
  - Base Prompt should be a full-width editor block with label above the textarea.
  - The textarea should use stable, readable dimensions and fill the available editor column.
  - Profiles should render as stacked panels, not several profiles side by side.
  - Each profile panel should have a clear header with profile id/name and compact summary metadata.
  - Profile controls should be grouped into sections:
    - Identity: name.
    - Execution: executor type.
    - Prompt: prompt mode and profile prompt template.
    - Updates: description/comment/result toggles.
    - Routing: allowed target states.
  - Prompt template and target states textareas should align with their labels and not appear as orphaned controls.
- Improve `/settings/workflow` only where shared form CSS causes the same readability problems:
  - labels above controls,
  - stable grid tracks,
  - no long single-row field collisions.
- Keep `/settings/runtime` visually consistent with the same Settings header/tabs and content width.
- Preserve current save, saving, saved, validation, and error popup behavior.
- Preserve current data shape, workflow version persistence, and DB-only runtime source.

## Non-Goals

- Do not change workflow schema, profiles schema, or persistence.
- Do not add drag-and-drop profile editing.
- Do not add profile creation/deletion unless already supported by the current form.
- Do not reintroduce `/workflows` or `/agent-settings`.
- Do not convert Settings into a marketing/landing page.
- Do not hide advanced fields that are currently editable; reorganize them instead.

## Acceptance Criteria

- [x] `/settings/agents` renders Base Prompt as a full-width, clearly labeled editor block.
- [x] The Base Prompt label appears above the textarea, never below or beside it.
- [x] `/settings/agents` does not show a large unusable blank area beside the Base Prompt editor at desktop width.
- [x] Profile panels are stacked vertically and each panel is readable without horizontal scanning.
- [x] Within each profile panel, Name, Executor, Prompt mode, Profile prompt template, update toggles, and Allowed target states are visually grouped.
- [x] Profile prompt template and Allowed target states textareas have labels directly above the controls.
- [x] Textareas keep fixed, stable heights and remain scrollable.
- [x] Controls do not overlap or wrap into unreadable rows at desktop width around 1365px.
- [x] Controls remain usable at mobile width around 390px.
- [x] Save button, saving state, saved notice, validation error, and error popup behavior still work on Workflow and Agents tabs.
- [x] Existing tab isolation remains intact: Workflow, Agents, and Runtime do not render as one long stacked page.

## Test Plan

- Add/update LiveView tests for `/settings/agents` asserting:
  - the Base Prompt section has the new layout class,
  - profile panels use the new stacked/grouped structure,
  - save button and validation error markup still render.
- Add/update CSS asset tests to assert the new layout classes exist:
  - settings content container,
  - settings action row,
  - agent prompt editor,
  - profile field grid,
  - profile grouped sections.
- Run browser verification against the in-app browser or Playwright screenshots at:
  - desktop width near 1365x768,
  - mobile width near 390x844.
- Run:
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Prefer editing the existing LiveView markup in `lib/symphony_elixir_web/live/admin_live.ex` and shared styles in `priv/static/dashboard.css`.
- Use form-oriented layout classes rather than relying on raw label/input flow.
- Keep cards to actual repeated profile panels and avoid nested decorative cards.
- Use CSS grid for profile internals:
  - short fields can sit in two columns on desktop,
  - textareas should span the full panel width,
  - mobile should collapse to one column.
- Keep help text short and close to the section it explains. The UI should show relationships through layout first, not paragraphs.
- The existing `workflow-textbox-*` fixed-height rules should remain, but width and label placement must be controlled by parent layout classes.
- Do not solve this by increasing textarea `rows`; the broken part is layout and hierarchy.
