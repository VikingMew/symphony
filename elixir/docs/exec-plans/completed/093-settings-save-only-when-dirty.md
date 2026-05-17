# 093 Settings Save Only When Dirty

## Goal

Make every Settings save action persist a new database workflow/project/settings version only when the submitted form has a meaningful diff from the current saved state.

If the operator clicks Save without any diff, the page should not create a new version, update timestamps, or append history. It should show a toast that says no save is needed.

## Status

Completed.

## Background

Settings pages currently provide explicit save buttons and save feedback, but repeated clicks can create unnecessary saves even when the form data is unchanged. That makes version history noisy, obscures real configuration changes, and makes it harder to trust "saved" as evidence that something actually changed.

The desired behavior is the same across Settings:

- changed form -> `Saving...` -> persisted -> `Saved`,
- unchanged form -> no persistence call -> toast says no changes / no save needed,
- invalid field values -> field error and no persistence,
- parseable semantic check failures -> save only if the draft differs, then refresh validation.

This should apply to all Settings pages that save data, not only Workflow.

## Scope

- Add dirty/diff detection before persistence for every Settings save path:
  - Projects,
  - Workflow,
  - Agents,
  - Runtime or other settings save forms if present.
- Compare normalized submitted form data with the currently saved canonical data, not raw browser strings.
- Skip persistence when there is no meaningful diff.
- Show an operator-facing toast for no-op saves, for example:
  - `No changes to save`,
  - `Project settings already up to date`,
  - `Workflow settings already up to date`,
  - `Agent settings already up to date`.
- Preserve current success/error toast behavior:
  - changed saves still show saving and saved,
  - persistence failures still show failed and reason,
  - field parse errors still show field-level errors.
- Prevent version history noise:
  - no-op Workflow save does not create a workflow version,
  - no-op Agents save does not create a workflow version,
  - no-op Project save does not update the project row or create project-related history entries.
- Refresh validation/check display only when needed:
  - if the current draft has no diff and validation/check state is already current, do not perform a save;
  - if validation is stale because external discovery/runtime state changed, allow refresh behavior without recording a new version.
- Keep page-specific version history scoped as currently designed.

## Out of Scope

- Do not redesign Settings layout.
- Do not add autosave.
- Do not disable Save buttons; clicking Save should still give feedback.
- Do not introduce legacy compatibility for old workflow file formats.
- Do not make semantic configuration failures block saving when the draft has a meaningful diff.
- Do not treat formatting-only or ordering-only differences as meaningful if the canonical model is equivalent.
- Do not change import/export semantics except where no-op imports already reuse the same save path.

## Acceptance Criteria

- [x] Workflow tab: clicking Save with no changes shows a no-op toast and does not call workflow persistence.
- [x] Agents tab: clicking Save with no changes shows a no-op toast and does not call workflow persistence.
- [x] Projects tab: clicking Save project with no changes shows a no-op toast and does not update the project.
- [x] Runtime tab or any other Settings save form follows the same no-op behavior if it has a save action.
- [x] Changed Workflow fields still persist a new workflow version and show saved feedback.
- [x] Changed Agents fields still persist a new workflow version and show saved feedback.
- [x] Changed Project fields still persist and show saved feedback.
- [x] Field parse errors still block saving before diff comparison where parsing is required to build canonical data.
- [x] Parseable drafts with semantic configuration errors still save when they differ from the current saved state.
- [x] Parseable drafts with semantic configuration errors do not save when they are unchanged; they show the no-op toast while retaining the current check messages.
- [x] Version history count does not increase on no-op saves.
- [x] Save buttons still use the existing `phx-disable-with="Saving..."` behavior for changed saves.
- [x] Tests cover no-op and changed saves for Projects, Workflow, and Agents.

## Test Cases

- Workflow no-op:
  - load `/settings/workflow`,
  - submit the form without changing fields,
  - assert a no-op toast is shown,
  - assert no `import_workflow` / workflow-version persistence call happened.
- Workflow changed:
  - change `initialize_timeout_ms` or another workflow-owned field,
  - submit,
  - assert saved toast,
  - assert one workflow persistence call with the changed canonical value.
- Agents no-op:
  - load `/settings/agents`,
  - submit without changing base prompt or profiles,
  - assert a no-op toast,
  - assert no workflow-version persistence call happened.
- Agents changed:
  - change base prompt or a profile prompt template,
  - submit,
  - assert saved toast and one workflow persistence call.
- Projects no-op:
  - submit an existing project with unchanged canonical values,
  - assert no-op toast,
  - assert no `update_project` call.
- Projects changed:
  - change repository URL, default branch, source strategy, or worktree settings,
  - assert saved toast and an update call.
- Semantic error with diff:
  - create a parseable workflow draft with a semantic error and a real diff,
  - assert it saves and shows configuration check failure.
- Semantic error without diff:
  - submit the same semantic-error draft again,
  - assert no-op toast and no new version.
- Ordering/normalization:
  - submit list fields with equivalent canonical values,
  - assert no-op behavior when the normalized model is unchanged.

## Implementation Notes

- Add a small canonical comparison layer instead of comparing raw params.
- Prefer reusing existing form normalization:
  - Workflow/Agents should compare the parsed `WorkflowForm.to_config/1` or generated raw workflow package against the current active workflow version's canonical representation.
  - Projects should compare parsed project attrs against the existing project struct after normalizing booleans, empty strings, integers, and defaults.
- The comparison should ignore non-persisted UI-only fields:
  - CSRF,
  - button params,
  - selected tab,
  - transient discovery data,
  - current save status/toast state.
- For Workflow and Agents, preserve section ownership:
  - Workflow tab compares only workflow-owned fields plus the shared full-version merge result it would save.
  - Agents tab compares only agent/profile/base-prompt-owned fields plus the shared full-version merge result it would save.
- Add helpers with explicit names, for example:
  - `workflow_changed?/2`,
  - `agents_changed?/2`,
  - `project_changed?/2`,
  - `canonical_workflow_for_compare/1`,
  - `canonical_project_attrs_for_compare/1`.
- Toast state should distinguish:
  - `:saving`,
  - `:saved`,
  - `:failed`,
  - `:unchanged`.
- No-op saves should not be considered failures. They should be neutral/info toasts.
- Keep validation/check messages visible after no-op save. Do not clear errors just because no persistence happened.
- If a no-op save happens while the page has stale validation data, prefer refreshing validation/checks without recording a new version.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- Browser check:
  - `/settings/projects` no-op save shows no-op toast,
  - `/settings/workflow` no-op save shows no-op toast,
  - `/settings/agents` no-op save shows no-op toast,
  - changed saves still show normal saved feedback.
- `git diff --check`

## Completion Deviations

- Runtime currently has no save form, so no runtime-specific code path was needed.
- Workflow/Agents no-op detection canonicalizes both current and submitted workflow packages through the structured `WorkflowForm` model before comparing. This intentionally ignores default fields inserted by the form model, such as default tool policy, when the effective model is otherwise equivalent.

## Dependencies

- Existing Settings save feedback from Task 051.
- Existing tabbed Settings ownership from Tasks 077, 083, 084, and 087.
- Existing semantic-check highlighting from Task 089.
- Existing Workflow/Agents section-scoped version history behavior from Task 083.
- Existing project source strategy fields from Tasks 090 and 091.

## Handoff Notes

The product rule is simple: Save should mean "persist a real change." If the operator clicks Save on an unchanged form, Symphony should acknowledge the click with a clear toast but should not create history noise. Do the comparison after canonical parsing, not on raw strings, so equivalent forms are treated as unchanged.
