# 049 Workflow Profile Editor Slice

## Goal

Add visible, editable profile configuration to `/workflows` so the structured workbench reflects the workflow contract beyond tracker/project/runtime fields.

Profiles are central to Symphony's workflow model. A page that edits workflow configuration but hides profiles is incomplete and misleading.

## Status

Completed.

## Background

The first structured workbench slice added textboxes for tracker, project/bootstrap, runtime, Codex, and base prompt. It did not expose:

- profile names;
- executor type;
- prompt mode;
- profile prompt template;
- allowed update policy;
- target states.

That means operators cannot see why refinement, implementation, and merge behavior differ. They also cannot understand or adjust the stage-specific instructions that Codex receives.

## Scope

- Add a Profiles section to `/workflows`.
- Render each top-level `profiles.<profile_id>` entry as a repeated editable panel.
- Show and edit:
  - profile id or stable key;
  - display name;
  - executor type;
  - prompt mode;
  - profile prompt template;
  - allowed update booleans for description/comment/result;
  - allowed target states.
- Preserve unknown profile fields when saving.
- Validate profile prompt rules before save.
- Show profile validation errors near the relevant profile panel.
- Keep the base prompt section separate from profile prompt templates.

## Out of Scope

- Drag-and-drop profile ordering.
- Full permissions UI for every possible future tool.
- Profile import from separate files.
- Changing runtime prompt composition semantics.

## Acceptance Criteria

- `/workflows` displays a Profiles section when profiles exist.
- Default refinement/implementation/merge profiles are visible.
- Editing a profile prompt template updates draft state.
- Editing allowed target states updates draft state.
- Saving serializes profiles back into the workflow package.
- Codex profiles using `extend` or `replace` cannot save with blank prompt templates.
- Manual/non-Codex profiles can use `disabled` where schema allows it.
- Tests cover profile render, edit, validation failure, and save serialization.

## Test Cases

- Render `/workflows` with active workflow; assert profile names are visible.
- Change implementation profile prompt template; save; assert serialized workflow includes the changed template.
- Blank a Codex `extend` profile template; assert save is rejected and no version is imported.
- Change allowed target states for a profile; save; assert serialized workflow includes the list.
- Import a workflow with custom profiles; assert all custom profile panels render.

## Implementation Notes

- Use repeated form field names that keep profiles keyed by profile id, for example `workflow[profiles][implementation][prompt_template]`.
- Avoid flattening all profiles into raw YAML textarea fields.
- Keep unknown profile keys in `_base_config` unless the edited field intentionally overwrites them.
- This slice can initially support existing profile ids without adding create/delete profile controls. Create/delete can follow in another plan if needed.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

First slice is implemented for existing/default profiles: profile panels render, editable fields submit through structured params, omitted tracker secrets remain preserved, and imported workflow packages show profiles without exposing `$LINEAR_API_KEY`.

Create/delete profile controls and field-local profile validation messages are still deferred.

## Dependencies

- Depends on Task 047 structured draft form.
- Related to completed profile contract work in Tasks 044, 045, and 046.

## Handoff Notes

Profiles are not advanced decoration; they define how the workflow actually behaves. Make them visible before adding more minor runtime fields.
