# 132 Settings Import Review Page

## Goal

Move Settings import into a dedicated page that supports both file upload and pasted document content, shows exactly what would change before applying it, and requires explicit user confirmation before imported settings affect the editable draft or persisted runtime configuration.

## Status

Completed.

## Background

Settings currently exposes an inline `Import Settings Package` panel inside the Workflow tab. It accepts pasted YAML and imports `workflow.yml` or `profiles.yml` into the structured draft. Import does not save or activate until the operator presses Save, but it still mutates the current draft immediately after submit.

That behavior is too easy to misread and too weak for larger settings packages:

- import is buried inside one Settings tab;
- only pasted YAML is supported, not file upload;
- the operator cannot inspect a structured before/after change preview before the draft is mutated;
- importing a package can affect settings across Workflow, Agents, and project-derived fields, but the action lives in the Workflow tab;
- confirmation happens indirectly through the later Save button, not at the import boundary.

Completed plan 047 already established that imports should populate structured form state, not become raw text editing. Current Settings import should keep that direction, but move the import workflow into a safer staged review page.

## Scope

- Add a dedicated Settings import route/page, for example `/settings/import`.
- Add a top-level Settings tab or action link labelled `Import`.
- Support two import sources:
  - file upload for supported package files;
  - pasted document/content textarea.
- Support current settings package formats:
  - `workflow.yml`;
  - `profiles.yml`;
  - any existing combined/split package shape supported by `WorkflowSettingsPackage` or `WorkflowForm`.
- Parse uploaded/pasted content into a staged import candidate without mutating the active settings draft.
- Show a review screen before apply:
  - detected package type;
  - validation result;
  - affected Settings areas such as Projects, Workflow, Agents, Runtime;
  - added/removed/changed fields in operator-readable form;
  - raw YAML preview or bounded source preview;
  - warnings for fields that are ignored, unsupported, or only valid in another package type.
- Require explicit confirmation before applying the import candidate.
- After confirmation, apply the candidate to the structured Settings draft and route the user to the owning Settings page or continue to a final save step.
- Preserve the existing rule that runtime configuration changes only after a normal Settings save creates/activates a workflow version.
- Add tests for upload, paste, preview, validation failure, confirmation, and cancellation.

## Out of Scope

- Do not make local `workflow.yml` or `profiles.yml` runtime sources again.
- Do not auto-save or auto-activate imported content.
- Do not import unbounded arbitrary document formats beyond supported text/YAML package content.
- Do not add drag-and-drop polish unless it falls out naturally from file upload support.
- Do not remove structured Settings editors.
- Do not expose secrets from uploaded content in logs or flash messages.

## Acceptance Criteria

- `/settings/import` exists and is reachable from Settings navigation.
- The page accepts pasted package content.
- The page accepts uploaded package files.
- Submitting content creates a staged review, not an immediate draft mutation.
- The review shows detected package type and affected Settings areas.
- The review shows a meaningful before/after diff for changed settings.
- Invalid YAML or invalid package content shows a clear error and does not mutate draft or persisted settings.
- The operator can cancel the staged import and return to Settings without changes.
- The operator must explicitly confirm before the import is applied to the Settings draft.
- Confirmed import still requires the normal Save flow before runtime configuration changes.
- Existing inline Workflow import is removed, replaced, or redirected so there is one clear import path.

## Test Cases

- Paste valid `workflow.yml`:
  - page parses content;
  - review shows `workflow` package type;
  - diff includes changed workflow states/transitions/settings;
  - draft is unchanged until confirm.
- Paste valid `profiles.yml`:
  - review shows `profiles` package type;
  - diff includes profile/base prompt changes;
  - draft is unchanged until confirm.
- Upload valid package file:
  - content is read and parsed;
  - review matches the pasted-content behavior.
- Invalid YAML:
  - page shows parse error;
  - no draft mutation;
  - no persistence import.
- Unsupported package shape:
  - page shows a package-type error;
  - no draft mutation.
- Cancel staged import:
  - staged candidate is discarded;
  - original draft remains unchanged.
- Confirm staged import:
  - structured draft is updated;
  - user is routed or prompted to save;
  - persistence is not called until Save.
- Existing save-only-when-dirty behavior still works after a confirmed import.

## Implementation Notes

Start by extracting import staging out of the current inline Workflow tab event.

Relevant current pieces:

- `SymphonyElixir.WorkflowSettingsPackage` owns import/restore/diff semantics for split settings packages.
- `SymphonyElixir.WorkflowForm` converts workflow packages to and from structured Settings drafts.
- `SymphonyElixirWeb.AdminLive` currently renders `settings_import_panel/1` and handles `import_settings_package`.

Prefer introducing an explicit staged import data structure:

```elixir
%{
  source: :upload | :paste,
  filename: String.t() | nil,
  detected_type: :workflow | :profiles | :combined,
  parsed: map(),
  proposed_draft: map(),
  diff: [map()],
  warnings: [String.t()]
}
```

Keep diff logic structured. Avoid raw string diff as the primary review surface because Settings drafts are structured maps and lists. A raw preview can be secondary and bounded.

File upload should use Phoenix LiveView upload support with size/type limits. Treat uploaded content as text. Bound preview and error output.

Confirmation should be a separate event from parse/stage. The parse/stage event must never call persistence or overwrite the working draft.

If Settings tabs are owned by one LiveView, store the staged import in socket assigns. If page reload persistence is desired, use a short-lived server-side store, but do not persist unconfirmed imports as active workflow versions.

## Verification

- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test --cover` passed with 424 tests, 0 failures, 2 skipped, 85.54% total coverage.
- Rendered Settings tests cover the `/settings/import` route, paste import staging, upload import staging, invalid YAML, cancellation, confirmation without persistence, and confirm-then-save.
- `WorkflowSettingsPackage.stage_import/3` is covered through LiveView staging and existing package import tests.

## Completion Deviations

Implemented as a dedicated `/settings/import` tab. Confirming an import applies the staged package to the editable LiveView draft and routes to the owning Settings tab; persistence still only happens through the existing Save actions.

## Dependencies

- Completed plan 047 for structured workflow import direction.
- Completed plan 075 for split workflow/profile settings files.
- Completed plan 077 for Settings tabs consolidation.
- Completed plan 093 for save-only-when-dirty behavior.
- Completed plan 098 for split package import behavior.
- Existing `WorkflowSettingsPackage` and `WorkflowForm` boundaries.

## Handoff Notes

The key product rule is staged review. Import should be a reversible proposal until the operator confirms it, and runtime behavior should not change until the normal Settings save path persists and activates the resulting configuration.
