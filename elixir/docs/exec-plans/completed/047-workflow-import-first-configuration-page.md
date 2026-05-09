# 047 Workflow Configuration Workbench Correction

## Goal

Correct the `/workflows` direction so Symphony no longer treats direct `WORKFLOW.md` text editing, generated workflow text, or upload-only import as the Web UI standard.

The Web workflow page should become a database-first configuration workbench:

- render the active workflow version as structured form state;
- use ordinary inputs, textboxes, selects, repeatable lists, and section panels for editing;
- support upload/import only as a way to populate that same structured form state;
- validate field, section, and whole-contract rules before persistence;
- show import/edit results and differences from the active version;
- save a database workflow version only after validation passes and the operator explicitly saves.

`WORKFLOW.md` remains an import/export package format. It must not be the primary Web editing surface, and upload/import must not replace the structured page logic.

## Status

Completed.

## Background

The long-term product direction already states that `/workflows` should not primarily be a large raw text editor. It should be a structured configuration page with file upload import and export support.

Recent short-term plans drifted away from that direction:

- Task 040 improved the current raw editor save path.
- Task 041 continued to describe generic workflow templates.
- Task 043 attempted to generate workflow text from the UI.

That direction is wrong for the target product. The corrective path is to stop investing in raw text editing and generated workflow text. The page should first model the workflow as editable structured state. The upload/import flow is only a migration bridge from `WORKFLOW.md` into that form state.

Existing validator work can still be reused, but it must be attached to the structured form state and import pipeline, not to a raw textarea as the main product interaction.

## Scope

- Replace the `/workflows` primary editing surface with a structured configuration workbench.
- Remove direct raw `WORKFLOW.md` editing from the primary UI.
- Do not add any workflow text generator or template generator UI.
- Add ordinary form controls for the workflow contract:
  - textboxes for scalar text values such as Linear project slug, workspace root, repository URL, default branch, Codex command, and prompt text;
  - numeric inputs for polling interval, checkout depth, max agents, max turns, and timeouts;
  - selects/toggles for tracker kind, sandbox policy, executor type, prompt mode, and activation behavior;
  - repeatable list editors for active states, terminal states, setup commands, cleanup commands, allowed transitions, profiles, and allowed updates.
- Render initial form state from the active database workflow version when one exists.
- Render an empty/setup form state when no active workflow exists.
- Add a `WORKFLOW.md` file upload import action that parses uploaded content and fills the same form state.
- Run validation on form changes and before creating a new workflow version.
- Display field-level errors beside inputs and section-level errors inside the relevant panel.
- Display top-level blocking errors when the complete workflow contract is invalid.
- Display a diff or summary between the current draft form state and the active workflow version.
- Save the draft form state as a database workflow version only after explicit confirmation.
- Keep version history and activation behavior.
- Keep export support as the way to obtain a full `WORKFLOW.md` artifact.
- Update user docs so `/workflows` is described as import/configuration/version management, not raw editing.

## Out of Scope

- Building the complete long-term structured editor for every workflow field in one pass.
- Removing file-backed startup mode from non-port CLI runs.
- Removing `WORKFLOW.md` import/export compatibility.
- Designing a workflow generator or starter template flow.
- Changing the underlying workflow package schema unless required for import normalization.
- Changing Linear state/profile runtime behavior.

## Acceptance Criteria

- `/workflows` no longer presents raw `WORKFLOW.md` textarea editing as the main action.
- `/workflows` presents a structured form with real textboxes/inputs for the most important workflow fields.
- Upload/import fills the same structured form state; it is not a separate save path.
- Editing a textbox updates draft state and validation output.
- Invalid draft state shows visible field/section errors and cannot create a workflow version.
- Importing invalid YAML or invalid workflow contract shows a visible error and does not mutate the current saved workflow version.
- Importing a valid workflow parses into the form, validates, and shows a preview/diff before persistence.
- Confirming a valid draft creates a new database workflow version.
- Activation validates the selected version before making it active.
- No UI path generates workflow text from repository URL/toolchain inputs.
- Documentation says `WORKFLOW.md` is an import/export artifact for Web mode, not the standard editing surface.
- Tests fail if the raw textarea save path returns as the primary workflow creation path.

## Test Cases

- Render `/workflows` with no active workflow and assert structured setup controls render instead of a raw workflow textarea.
- Render `/workflows` with an active workflow and assert core textboxes are populated from the active version.
- Change a textbox such as workspace root or Linear project slug and assert draft state and validation output update.
- Add/remove a list item such as an active state, setup command, or allowed transition and assert validation updates.
- Upload malformed `WORKFLOW.md`; assert validation error and no persistence import call.
- Upload syntactically valid but semantically invalid workflow; assert field/contract error and no persistence import call.
- Upload valid `WORKFLOW.md`; assert parsed values populate the structured form and save confirmation is available.
- Confirm valid draft; assert `Persistence.import_workflow/3` is called with a serialized workflow package and source `web_form`.
- Activate invalid historical version; assert activation is rejected before `activate_workflow_version/1`.
- Assert no `generate workflow`, `template mode`, or repository/toolchain generator controls render on `/workflows`.
- Export current active version; assert exported content can be uploaded again and validates equivalently.

## Implementation Notes

- Treat structured form state as the page source of truth.
- Treat upload as a way to replace or merge draft form state, not as the page's main logic.
- The raw artifact can still be persisted as `raw_workflow_md` for audit/export, but UI state should be derived from parsed structured data.
- Reuse `Workflow.parse_content/1`, `Config.Schema.parse/1`, and semantic validation through a workflow validator module.
- Add a temporary draft assign/state instead of saving immediately on edit or upload.
- Keep confirmation explicit so operators can inspect validation and diff before creating a version.
- If the full editor is too large for one implementation slice, build a minimal writable structured workbench first:
  - Tracker section: project slug, active states, terminal states.
  - Project / Bootstrap section: repository URL, branch, checkout depth, setup commands, cleanup commands.
  - Workspace section: root.
  - Codex section: command and sandbox.
  - Agent section: max concurrent agents and max turns.
  - Prompt section: base prompt textbox.
  - Versions section: active version, draft diff, save/activate controls.
- Existing raw editor tests should be rewritten around upload/import behavior, not updated as fixtures for textarea editing.
- Existing completed plans that mention raw editing are historical records. Do not use them as product direction for new work.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/workflow_store_fake_persistence_test.exs test/symphony_elixir/core_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`
- [x] `mise exec -- mix build`

## Completion Deviations

First implementation slice builds a writable structured workbench for tracker, project/bootstrap, runtime, Codex, and base prompt fields. It does not yet implement the full long-term editor for profiles, allowed transitions, allowed updates, or field-local error rendering for every nested contract rule.

Upload import now fills the same structured draft form and does not create a workflow version until the operator saves the draft.

## Dependencies

- Long-term target documented in `docs/workflow_page_design.zh-CN.md`.
- Database workflow version import/export foundation from earlier persistence work.
- Workflow validation logic from the current correction work may be reused if it remains independent from raw textarea UI.

## Handoff Notes

Start by changing the product surface, not by adding another compatibility path. The page should make structured editing and version management obvious. Upload/import is a secondary way to populate the structured draft, while raw text editing should disappear from the normal workflow.

Do not revive workflow generation. A repository URL, toolchain, or language selector can be useful later as structured project configuration fields, but it must not generate a `WORKFLOW.md` blob for users to edit.
