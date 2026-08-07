# Task 005: Manage Configuration in Web UI

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 001, Task 002, Task 003
**Created**: 2026-05-01

## Goal

Add Web UI screens for managing Symphony configuration, including the complete workflow contract currently represented by `WORKFLOW.md`.

## Background

Symphony cannot remain dependent on temporary file edits for long-term operation. Operators need a UI for configuring projects, tracker settings, workspace settings, hooks, agent limits, Codex command/sandbox policy, and prompt templates.

The full `WORKFLOW.md` must be configurable. The UI should support both structured form editing and raw workflow editing so advanced users can work directly with the underlying contract.

## Scope

- Add project settings pages.
- Add workflow settings pages.
- Support editing YAML front matter fields through forms.
- Support editing Markdown prompt body.
- Support raw full `WORKFLOW.md` editing.
- Validate changes before activation.
- Save each change as a new workflow version.
- Show workflow version history.
- Show diff/summary between active and previous versions.
- Support import/export of `WORKFLOW.md`.

## Out of Scope

- Fine-grained user roles.
- Multi-tenant authorization.
- Secret rotation workflows beyond selecting/storing secret references.
- Multi-project Linear fan-out behavior. That belongs to Task 006.

## Acceptance Criteria

- [ ] Authenticated users can view current active workflow configuration.
- [ ] Authenticated users can edit tracker, polling, workspace, hooks, agent, codex, server, and prompt sections.
- [ ] Authenticated users can edit the raw full `WORKFLOW.md`.
- [ ] Invalid YAML/config is rejected with actionable errors.
- [ ] Valid changes create a new immutable workflow version.
- [ ] Operators can activate a previous workflow version.
- [ ] Operators can import and export `WORKFLOW.md`.
- [ ] Existing orchestrator behavior uses the selected active workflow version.
- [ ] Tests cover form validation, raw editor validation, version creation, activation, import, and export.

## Test Cases

- Authenticated user can open project settings page.
- Unauthenticated user cannot open configuration pages.
- Structured form renders current tracker, polling, workspace, hooks, agent, codex, server, and prompt values.
- Saving valid structured form changes creates a new workflow version.
- Saving invalid structured form changes shows validation errors and does not activate a new version.
- Raw editor renders complete `WORKFLOW.md`.
- Saving valid raw `WORKFLOW.md` creates a new workflow version.
- Saving invalid raw YAML or invalid config schema shows actionable errors.
- Importing a `WORKFLOW.md` creates a workflow version.
- Exporting the active workflow returns complete front matter and prompt body.
- Activating a previous version updates the active workflow.
- Workflow version history page lists versions in expected order.

## Implementation Notes

- Use Phoenix LiveView and HEEx components.
- Keep the UI operational and dense; this is a control plane, not a landing page.
- Reuse Ecto changesets and workflow schema validation.
- Prefer a split editor:
  - structured tabs for common settings
  - raw editor for the complete contract
- Do not store secrets directly in workflow YAML once secret references exist.

## Verification

- LiveView tests for configuration pages.
- Persistence tests for workflow version creation and activation.
- Import/export round-trip tests.
- `mise exec -- mix test`
- Manual check: edit a workflow field in UI, save, confirm new version, restart service, confirm active config remains.

## Completion Deviations

- Implemented raw full `WORKFLOW.md` editing, workflow version creation, version listing, and activation.
- Structured field-by-field controls are not yet complete; the raw editor is the authoritative configuration UI for this pass.
- Import/export compatibility is provided through raw workflow storage and export from active workflow versions.

## Handoff Notes

- Record which workflow fields have structured form controls and which are raw-only.
- Record any validation errors that remain hard to present cleanly.
- Record UX follow-ups for Task 007.
