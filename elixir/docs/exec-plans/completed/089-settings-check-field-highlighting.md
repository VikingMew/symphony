# 089 Settings Check Field Highlighting

## Goal

Make Settings configuration check failures local and actionable by highlighting the owning field, row, or card with a red border and red title/label when a check detects a non-compliant value.

The operator should be able to save parseable drafts, see the saved feedback, and still immediately understand which visible configuration item needs attention.

## Status

Completed.

## Background

Settings now separates saveability from runtime correctness:

- field parse and persistence errors can block saving,
- semantic configuration checks do not block saving,
- runtime validation can still block listening or dispatch.

That split is correct for long forms, but the current failure presentation is still too global. A top-level message like `Configuration check failed` tells the operator that something is wrong, but not which field owns the problem. This is especially confusing when a check involves state names shared between Workflow, Agents, Projects, and Linear discovery.

The UI needs a consistent visual contract:

- if the bad value is on the current page, mark that exact field, row, or card,
- if the bad value belongs to another Settings tab, show a summary that names the target tab,
- if the failure is environment/runtime-only, keep it in the summary and do not fake-highlight an unrelated Settings field.

## Scope

- Build a structured mapping from configuration check issues to Settings UI targets.
- Highlight check-owned targets with:
  - red border on the containing field, row, or card,
  - red title/label for that target,
  - accessible invalid state where the target is a form field.
- Support at least these ownership areas:
  - Projects tab: Linear project slug, repository URL, default branch, enabled project state.
  - Workflow tab: active states, terminal states, review states, transitions, routed states, bootstrap fields, lifecycle hook fields.
  - Agents tab: profile prompt policy, allowed update fields, allowed target states, executor/profile identity fields.
  - Runtime tab: runtime/env setup messages that can be shown but are not owned by a normal editable field.
- Keep the top-level configuration check summary, but make it a navigation aid rather than the only feedback.
- Preserve current save behavior:
  - parseable drafts can be saved even when semantic checks fail,
  - save shows `Saving...`, `Saved`, or failed feedback,
  - semantic check failures refresh after save.
- Highlight cross-tab errors only on the owning tab. The current tab should show a clear summary like `Open Agents / Profile implementation / Allowed target states`.
- Include Linear state length violations in the same target mapping. For example, a state name longer than Linear's 25-character limit should highlight the state list, transition row, or profile target-state field that contains it.

## Out of Scope

- Do not redesign the entire Settings layout in this plan.
- Do not reintroduce disabled save buttons for semantic check failures.
- Do not auto-fix state names or transitions.
- Do not create Linear states, projects, or teams from Symphony.
- Do not persist raw Linear discovery snapshots.
- Do not move API token configuration into the Web UI.
- Do not make tracker kind or Linear endpoint editable.
- Do not add legacy compatibility paths for old workflow file layouts.

## Acceptance Criteria

- [x] A Workflow check failure involving `active_states` highlights the Workflow active states field with a red border and red label/title.
- [x] A Workflow transition failure highlights the specific transition row or the smallest available transition container.
- [x] A profile target-state failure highlights the owning profile's `Allowed target states` field in the Agents tab.
- [x] A project configuration failure highlights the owning project field in the Projects tab.
- [x] If a Workflow page summary includes an Agents-owned failure, the Workflow page does not highlight an unrelated Workflow field and instead points to Agents.
- [x] Environment/runtime-only failures remain summary-only and do not create fake field highlights.
- [x] Check highlights are visually distinct but compatible with existing field parse errors.
- [x] Check-highlighted fields expose `aria-invalid="true"` and a stable description where practical.
- [x] Saving a parseable draft with semantic check failures still shows saved feedback.
- [x] After save, semantic checks refresh and highlight the current issue set.
- [x] Removing or fixing the bad value clears the red highlight after validation refresh.
- [x] Tests cover same-tab and cross-tab ownership for check highlights.

## Test Cases

- Workflow state check:
  - create a parseable workflow draft with an unknown active state,
  - save it,
  - assert the save success feedback is visible,
  - assert the active states field has the check-invalid class and red-title class.
- Workflow transition check:
  - create a transition that references an unknown state,
  - assert the transition row/container is highlighted,
  - assert unrelated workflow fields are not highlighted.
- Agent profile target-state check:
  - create a profile whose allowed target state is not in the workflow state set,
  - assert `/settings/workflow` shows a summary pointing to Agents,
  - assert `/settings/agents` highlights that profile's target-state field.
- Project check:
  - leave a required repository URL or Linear project slug invalid for an enabled project,
  - assert the Projects tab highlights the owning project field.
- Linear state length check:
  - use `Needs Implementation Review` as a state or target state,
  - assert the field containing that value is highlighted and the message explains the 25-character limit.
- Runtime/env-only check:
  - simulate a missing `LINEAR_API_KEY`,
  - assert the message is visible,
  - assert no editable field is incorrectly highlighted.
- Clear state:
  - fix a highlighted value,
  - save or refresh validation,
  - assert the red field/card state is removed.

## Implementation Notes

- Prefer structured issue ownership over parsing human-readable error strings.
- If the current validator only returns a string for a check, add an internal issue-mapping layer near the Settings LiveView that derives targets from the draft data and known check result categories.
- Keep semantic check targets separate from parse `field_errors`, but allow both to use the same visual language.
- Suggested target shape:
  - `tab`: `:projects | :workflow | :agents | :runtime`,
  - `scope`: stable section/profile/project identifier,
  - `field`: stable field identifier,
  - `message`: concise operator-facing message,
  - `severity`: `:error | :warning`.
- Add helper functions rather than scattering conditionals through HEEx:
  - `check_target?/3`,
  - `field_check_class/3`,
  - `section_check_class/3`,
  - `check_title_class/3`,
  - `check_messages_for/3`.
- Add stable IDs/classes for repeated rows that currently lack them, especially:
  - workflow transition rows,
  - agent profile cards,
  - profile allowed target-state fields,
  - project cards and project-owned fields.
- Suggested CSS classes:
  - `.settings-check-invalid`,
  - `.settings-check-title-invalid`,
  - `.settings-check-message`.
- Red styling should apply to the owning field/card border and title/label only. Avoid making the whole page red.
- For cross-tab failures, summary entries should include the owning tab and section name, for example:
  - `Agents / implementation / Allowed target states`,
  - `Projects / Default / Linear project slug`.
- Keep Settings tab ownership aligned with the product model:
  - Projects owns project slug, repository URL, and default branch,
  - Workflow owns shared routing/state semantics,
  - Agents owns profile policy and profile target states,
  - Runtime owns environment/runtime setup guidance.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

- The implementation keeps the existing validator return protocol intact. Settings derives UI check targets from the current draft and known validation message shapes rather than introducing a new structured validator result in this task.
- Transition rows use the existing CSS grid structure, so the red row state is applied through the row class and child input/select styling.
- Project-owned setup checklist issues highlight the existing default project fields; create-project fields are not highlighted because the checklist is about the configured default project required by runtime.

## Dependencies

- Existing Settings save feedback behavior from Task 051 and later validation updates.
- Existing Settings tab structure for Projects, Workflow, Agents, and Runtime.
- Existing semantic validation split where semantic check failures do not block saving parseable drafts.
- Existing Linear state validation, including the 25-character state-name limit.
- Existing shared Linear discovery state from Task 088.

## Handoff Notes

The main product rule is locality: a check failure should highlight the place where the operator can fix it. If the fix belongs to another tab, do not highlight a nearby but unrelated field. The summary should route the operator to the correct Settings tab, and the owning tab should render the red border/title on the exact field or smallest practical container.
