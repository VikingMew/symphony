# 050 Workflow Phase And State Routing Editor

## Goal

Expose the workflow phase/state routing model on `/workflows` so operators can understand which states run which profile and where human review gates sit.

The current structured page shows active and terminal state lists, but it does not show the workflow phases/states that route work to profiles. This hides the most important behavior of the workflow.

## Status

Completed.

## Background

The workflow contract includes more than tracker state names. It includes:

- `workflow.states`;
- state-to-profile routing;
- human review states;
- allowed transitions;
- actor/profile restrictions.

If the page only shows active/terminal lists, users can edit names without understanding how those names map to refinement, implementation, merge, or manual review phases.

The user called this out as the page not reflecting profile and "phrase" concerns. Treat that as phase/stage/state routing: the UI needs to show the workflow phases and their relationship to profiles.

## Scope

- Add a Workflow Phases / State Routing section to `/workflows`.
- Render each `workflow.states.<state>` entry with:
  - state name;
  - assigned profile;
  - whether it is active, terminal, or review-adjacent where derivable.
- Render human review states.
- Render allowed transitions in a readable table/list.
- Allow editing state-to-profile mapping for existing states.
- Allow editing human review states as a repeatable list.
- Preserve allowed transitions on save even if full editing is not implemented in the first slice.
- Validate that every referenced profile exists.
- Validate that phase/state routing stays coherent with profile target states.

## Out of Scope

- Full graph visualization.
- Drag-and-drop workflow designer.
- Automatic Linear state discovery.
- Automatically creating missing Linear states.
- Complete transition create/delete UI if that is too large for this slice.

## Acceptance Criteria

- `/workflows` shows a Workflow Phases or State Routing section.
- Existing states show their assigned profiles.
- Human review states are visible.
- Allowed transitions are visible at least read-only in the first slice.
- Changing a state's profile updates draft state and save serialization.
- Saving is rejected when a state references a missing profile.
- Tests cover render, edit, validation, and serialization.

## Test Cases

- Render `/workflows`; assert `Ready`, `In Progress`, and `Merging` show their assigned profiles.
- Change `Ready` from `implementation` to another existing profile; save; assert serialized workflow changes.
- Change a state to a missing profile; assert validation error and no persistence import.
- Render human review states; assert they are visible.
- Render allowed transitions; assert actor/profile restrictions are visible.

## Implementation Notes

- Keep this section distinct from Tracker active/terminal states. Tracker states describe Linear visibility; workflow state routing describes execution behavior.
- Use select controls for profile assignment once profiles are available from the draft.
- If allowed transition editing is deferred, render transitions read-only and record that as a completion deviation.
- Avoid using a graph-only visualization; the page needs concrete editable controls.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

First slice is implemented for existing/default state routing: states render with profile selects, human review states are editable, and allowed transitions render read-only.

Full allowed-transition editing and field-local routing validation messages are still deferred.

## Dependencies

- Depends on Task 047 structured draft form.
- Benefits from Task 049 profile editor so state routing can use profile ids in selects.

## Handoff Notes

Do not collapse this into the tracker section. Tracker state lists and workflow phase routing are related but not the same thing.
