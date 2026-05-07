# 048 Workflow Tracker Fixed Fields Cleanup

## Goal

Fix the `/workflows` tracker section so it no longer exposes fields that operators should not edit on this page.

Tracker `kind` and `endpoint` are implementation/runtime choices that are effectively bound together for the current Linear workflow. The page should not present them as editable textboxes. Tracker API key should not be shown or edited on the workflow page.

## Status

Completed.

## Background

The first structured workbench slice exposed `tracker.kind`, `tracker.endpoint`, and `tracker.api_key` as ordinary inputs. That is the wrong product surface:

- `kind=linear` and the Linear endpoint are coupled for this product path.
- The API key is secret/configuration material and should not appear in this form.
- Showing those fields implies they are normal workflow-level knobs, which is misleading.

The workflow page should focus on project/workflow behavior: project slug, assignee, states, profiles, phase routing, workspace/project bootstrap, Codex policy, and prompt.

## Scope

- Remove editable tracker `kind` input from `/workflows`.
- Remove editable tracker `endpoint` input from `/workflows`.
- Remove tracker API key input from `/workflows`.
- Preserve existing values when loading, editing, importing, and saving a draft.
- Show tracker kind as read-only summary text only if useful.
- Do not show endpoint unless there is a diagnostics reason to display it.
- Do not display the API key value, placeholder, or environment reference in the form.
- Update form conversion code so omitted fixed/secret fields are retained from the base config or defaults.
- Update tests that currently assert tracker fields render.

## Out of Scope

- Changing how Linear credentials are configured globally.
- Adding a settings page for secrets.
- Supporting non-Linear tracker kinds in this UI.
- Changing Linear diagnostics behavior.

## Acceptance Criteria

- `/workflows` no longer renders inputs named:
  - `workflow[tracker_kind]`
  - `workflow[tracker_endpoint]`
  - `workflow[tracker_api_key]`
- Saving a draft preserves the effective tracker kind and endpoint.
- Saving a draft preserves the API key source without exposing it in HTML.
- Tests assert the API key is absent from rendered page HTML.
- Existing valid workflow versions still load into the draft form.

## Test Cases

- Render `/workflows`; assert Project slug and Assignee inputs exist.
- Render `/workflows`; refute editable tracker kind, endpoint, and API key inputs.
- Render `/workflows` with an active workflow using `$LINEAR_API_KEY`; assert page HTML does not include `$LINEAR_API_KEY`.
- Save a draft after changing project slug; assert serialized workflow still contains the expected tracker kind and endpoint.
- Import a workflow package containing an API key reference; assert import succeeds but the key is not rendered.

## Implementation Notes

- `WorkflowForm.to_config/1` should keep fixed fields from `_base_config` when the form does not submit them.
- For a new empty draft, default to `tracker.kind = linear` only if the current product path requires Linear. If memory tracker setup is still needed for tests/setup, keep the default explicit in helper code rather than exposing it as an input.
- Avoid masking secret values with `******` in this page; even a masked field implies the secret is edited here.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

None.

## Dependencies

- Depends on the structured workflow workbench from Task 047.

## Handoff Notes

This is a product correction, not only a security cleanup. The operator should not be invited to edit fields that are not real workflow decisions.
