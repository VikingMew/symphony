# 098 Settings Split Package Import

## Goal

Restore clear Settings import actions for the current workflow package format. Operators should be able to import `workflow.yml` and `profiles.yml` into the structured Settings draft, review validation/diff, and then save a database workflow version. Import must be an explicit UI action, not a CLI path and not a runtime startup fallback.

## Status

Completed.

## Background

The product direction is database-first runtime configuration. Local `workflow.yml` and `profiles.yml` are import/export artifacts only. Earlier UI iterations had import affordances, but the current Settings surface no longer exposes usable import buttons. This makes first setup and migration awkward, especially because the correct Symphony seed Base Prompt already exists in the checked-in `profiles.yml` while the empty database form shows no real configuration.

The long-term page design already says Settings should support upload/import of split workflow packages, with `workflow.yml` owning runtime/routing and `profiles.yml` owning `base_prompt` plus agent profiles. That import should populate the same structured forms used for manual edits.

## Scope

- Add one explicit import entry in Settings, outside the Agents tab.
- Use one import form with:
  - one YAML input;
  - one Import button.
- Do not add a file-kind selector. The YAML document itself is the source of truth:
  - documents with top-level `profiles` or `base_prompt` are treated as `profiles.yml` / `profiles.yaml`;
  - all other valid mapping documents are treated as `workflow.yml` / `workflow.yaml`.
- Do not show two side-by-side boxes for `workflow.yml` and `profiles.yml`.
- Parse uploaded files through the existing `Workflow.load_split_package`/parser boundary or an equivalent shared parser, not ad hoc string manipulation.
- Import fills the structured draft state; it must not immediately activate runtime without the normal Save action.
- Show import status separately from save status:
  - importing;
  - imported into draft;
  - import failed with parse/validation error.
- After import, show validation/check results and dirty state so Save can persist only changed configuration.
- Make no-op import obvious: if imported content is equivalent to current active settings, show the existing no-changes toast/state instead of creating a version.
- Support importing this repository's `elixir/workflow.yml` and `elixir/profiles.yml` one file at a time as the practical seed path.
- Update docs and tests for the first-run setup flow.

## Out of Scope

- Do not reintroduce local file runtime fallback.
- Do not add CLI import.
- Do not automatically import files on application start.
- Do not support legacy `WORKFLOW.md` as the primary path unless existing parser code already requires keeping it for export compatibility.
- Do not bypass structured Settings validation or save feedback.
- Do not persist secrets from import files into workflow configuration.

## Acceptance Criteria

- Settings exposes a visible import action again.
- Operators can import `workflow.yml` and `profiles.yml` into the Settings draft by pasting one YAML document at a time.
- The system detects the imported document type from top-level YAML fields; operators do not choose a kind manually.
- Import controls do not appear under `/settings/agents`.
- Imported `profiles.yml` `base_prompt` appears in `/settings/agents` Base Prompt after import.
- Imported profiles appear in `/settings/agents` as structured profile forms.
- Imported workflow states/routing/runtime settings appear in their owning Settings tabs.
- Importing invalid YAML shows an import error and does not mutate saved active workflow version.
- Importing a semantically invalid package may populate the draft when parseable, but surfaces configuration checks and does not start runtime listening until saved and valid enough for runtime.
- Importing valid changed settings marks the draft dirty and Save creates/activates a new workflow version.
- Importing equivalent settings produces a no-change message and does not create a duplicate workflow version.
- Save feedback remains `saving` -> `saved` or error popup, consistent with existing Settings save behavior.

## Test Cases

- Render `/settings/workflow` and assert one import control is visible.
- Render `/settings/agents` and assert import controls are absent.
- Import a valid `workflow.yml` document and assert the UI reports `workflow.yml` imported.
- Import a valid `profiles.yml` document and assert the UI reports `profiles.yml` imported.
- Assert imported draft shows the base prompt, profiles, workflow states, and runtime fields in the correct tabs.
- Save imported draft and assert one database workflow version is created and active.
- Upload malformed `profiles.yml`; assert visible import error and no persistence save call.
- Upload valid YAML with invalid workflow semantics; assert draft can show field-level/check errors and runtime remains disabled until resolved.
- Import equivalent current active package; assert no new workflow version and visible no-op feedback.
- Verify import does not render or persist Linear API tokens.

## Implementation Notes

- Keep the import surface small: one YAML input and one Import button.
- `workflow.yml` and `profiles.yml` distinction is detected from the YAML document, not from a user-selected field.
- Detection rule is intentionally simple and visible in code: top-level `profiles` or `base_prompt` means profiles package; otherwise a valid mapping is a workflow package.
- One-file-at-a-time import is expected; import feedback should say which package type was imported into the draft.
- Preserve current section version history model: import modifies a draft, save creates the version.
- Use existing `WorkflowForm.from_loaded/1` and `WorkflowForm.to_config/1` paths so imported data and manually edited data converge.
- Keep import feedback separate from save feedback to avoid showing `saved` for an import-only draft.
- The seed path for a new local Symphony setup should be documented as uploading `elixir/workflow.yml` and `elixir/profiles.yml`, then saving.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/core_test.exs` - 99 tests, 0 failures.
- `mise exec -- mix lint` - no issues.
- `mise exec -- mix build`
- `mise exec -- mix test` - 359 tests, 0 failures, 2 skipped.
- `mise exec -- mix format --check-formatted`
- `git diff --check`
- Rendered `/settings/workflow` and `/settings/agents` against a temporary local server on port 4012:
  - Workflow rendered one `import[yaml]` textarea, no `import[kind]`, and the auto-detection help copy.
  - Agents rendered no import controls and still rendered Base Prompt.

## Completion Deviations

- The delivered UI is a paste/import form rather than browser file upload. This matches the current one-YAML-input scope; future upload controls should reuse `Workflow.parse_settings_yaml/1`.
- Importing profiles into the Workflow tab revealed that tab navigation was refreshing the draft from persistence and dropping unsaved imported profile content. The LiveView now preserves dirty workflow draft state across Settings tab changes until Save or no-op Save clears it.

## Dependencies

- Completed plan 076 for `profiles.yml` owning `base_prompt`.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 087 and 088 for Settings-owned discovery state.
- Completed plan 093 for save-only-when-dirty behavior.
- Completed plan 097 prevents setup-required placeholder prompt from being mistaken for an imported seed prompt.

## Handoff Notes

The import path is a migration/setup assistant for Settings. It must converge into the same draft/save/validation/version history flow as manual edits. If implementation finds existing import handlers still wired to old page assumptions, update them instead of adding a second hidden import pipeline.
