# 051 Workflow Save Feedback State

## Goal

Make the `/workflows` save action behave like an ordinary modern web form: clicking Save gives immediate feedback, the button visibly enters a saving state, success is acknowledged, and failures are shown in a popup/toast that the operator cannot miss.

## Status

Completed.

## Background

The structured workflow workbench now has many editable fields, but the save interaction is too quiet. From the operator's point of view, clicking "Save workflow version" can look like nothing happened. That is unacceptable for a configuration page that creates a database workflow version.

The page needs a clear client-visible lifecycle:

- idle: draft can be edited and Save is available when the draft is valid;
- saving: Save was clicked and the request is in flight;
- saved: the server created a workflow version and the page confirms it;
- failed: validation, serialization, persistence, or unexpected server errors are shown in a popup/toast.

This is separate from deeper validation work. Even if validation is still coarse in some sections, the save interaction itself must be obvious.

## Scope

- Add explicit save feedback state to `/workflows`.
- Change the Save button label and disabled state while a save is in flight.
- Prevent duplicate saves while the same save request is in progress.
- Show a success popup/toast when a workflow version is saved.
- Show an error popup/toast when saving fails.
- Keep existing inline validation messages, but also surface blocking save failures in the popup.
- Ensure import and edit draft actions clear or update stale save feedback appropriately.
- Preserve LiveView behavior when JavaScript is enabled.
- Keep non-JavaScript degradation acceptable through server-rendered flash or page-visible status text.
- Add tests that assert save success and save failure feedback is rendered.

## Out of Scope

- Redesigning every validation error as field-local UI.
- Adding a complete unsaved-changes guard.
- Adding optimistic persistence.
- Changing workflow version storage semantics.
- Changing import parsing semantics.

## Acceptance Criteria

- Clicking Save immediately changes the visible button state to a saving label such as `Saving...`.
- While saving, the Save button cannot be clicked again.
- On successful save, the page shows a visible success popup/toast with the created workflow version context where available.
- On successful save, the button returns to a stable saved/idle state.
- On validation or persistence failure, the page shows a visible error popup/toast.
- Error popup text includes the actionable reason when available.
- Editing the draft after a successful save clears the stale saved status.
- Upload/importing a workflow package clears stale saved status and shows import feedback separately.
- Tests cover successful save feedback.
- Tests cover failed save feedback.

## Test Cases

- Render `/workflows`; click Save with a valid draft; assert a success popup/toast appears.
- Simulate slow persistence; assert the Save button renders a saving state and is disabled while the request is in flight.
- Simulate persistence failure; click Save; assert an error popup/toast appears and no false success state is shown.
- Submit an invalid draft; assert save is rejected and the popup/toast contains the validation reason.
- After a successful save, edit a textbox such as project slug; assert the saved status is cleared or replaced with a draft-changed state.
- After a successful save, import a new workflow package into the draft; assert stale saved status is cleared.

## Implementation Notes

- Prefer Phoenix LiveView's built-in form feedback primitives where possible:
  - use `phx-submit` for the save form;
  - use `phx-disable-with="Saving..."` or equivalent button state for the in-flight label;
  - use flash or a local assign-backed toast component for success and failure messages.
- Keep popup/toast rendering inside the existing dashboard design system instead of adding a browser `alert`.
- If using flash, ensure it is visible on the same LiveView without requiring a full navigation.
- Separate save feedback from import feedback so a successful import is not confused with a saved workflow version.
- Do not hide server validation failures inside logs; every failed save path should return a visible UI message.
- If the current save handler catches only validation errors, extend it so persistence exceptions are converted into user-visible errors and still logged for debugging.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`
- [ ] Browser check on `/workflows`: click Save and observe saving, saved, and failure states.

## Completion Deviations

Browser click verification was not run against the local database to avoid creating an extra workflow version in the operator's current runtime database. LiveView tests cover successful save feedback, validation failure feedback, persistence failure feedback, and the `phx-disable-with="Saving..."` in-flight button state.

## Dependencies

- Depends on Task 047 structured workflow workbench.
- Related to Task 048 tracker cleanup because save feedback must not expose secret fields.
- Related to Tasks 049 and 050 because profile/routing validation failures must be visible when save is blocked.

## Handoff Notes

This is not a cosmetic polish task. Save without feedback makes the workflow editor feel broken and can cause duplicate or uncertain configuration writes. Implement the state transition first, then improve field-local validation later.
