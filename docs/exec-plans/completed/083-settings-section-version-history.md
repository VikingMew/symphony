# 083 Settings Section Version History

## Goal

Split settings history by page ownership. `/settings/workflow` and `/settings/agents` should not present one shared "Version History" list as if every saved workflow version belongs to the currently visible page.

## Context

The persistence layer still stores a complete workflow package in each `workflow_versions` row. That is useful for runtime activation and auditability, but the settings UI is now split by ownership:

- Workflow owns tracker, project/bootstrap, hooks, runtime/codex values, workflow states, human review states, and allowed transitions.
- Agents owns the shared base prompt and execution profiles.
- Runtime is currently read-only summary.

Showing a single shared history only under Workflow is misleading after the settings split. An Agents save creates a complete workflow version too, but the user expects to find that change in Agents history, not in Workflow history.

## Scope

- Mark new saves with a section-specific source:
  - `web_workflow_settings`
  - `web_agent_settings`
- Do not keep older `web_form` versions visible; alpha-stage Settings history should only show current page-specific sources.
- Add an Agents version history section.
- Filter each page's history to versions saved for that page.
- Replace direct "Activate" semantics in settings history with section restore semantics:
  - restoring a Workflow history row only restores Workflow-owned fields into the current active draft;
  - restoring an Agents history row only restores prompt/profile fields into the current active draft;
  - the restore saves a new complete active workflow version with the page-specific source.
- Preserve runtime reload and validation behavior after restore.

## Non-Goals

- Do not add a new database table in this step.
- Do not split runtime storage into multiple active records yet.
- Do not add Runtime edit history until Runtime has editable settings.
- Do not rewrite existing historical rows.

## Acceptance Criteria

- [x] Workflow saves use `web_workflow_settings`.
- [x] Agent saves use `web_agent_settings`.
- [x] `/settings/workflow` Version History lists current workflow settings saves only.
- [x] `/settings/agents` Version History lists agent saves only.
- [x] Agents history is rendered on the Agents page.
- [x] Restoring an Agents history row keeps current Workflow-owned fields and restores only prompt/profiles.
- [x] Restoring a Workflow history row keeps current Agents-owned fields and restores only Workflow-owned fields.
- [x] Restore validates before saving and reports success/error in the existing toast pattern.
- [x] Existing tests cover separated histories and scoped restore.

## Test Plan

- Add LiveView fake persistence tests for:
  - page-specific save source values,
  - workflow page filtering,
  - agents page filtering,
  - scoped restore behavior.
- Run:
  - `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`
