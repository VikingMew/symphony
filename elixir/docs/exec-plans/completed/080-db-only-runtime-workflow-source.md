# 080 DB Only Runtime Workflow Source

## Goal

Make SQLite active workflow versions the only runtime workflow source. Local `workflow.yml` and `profiles.yml` files should remain package/exchange formats, but they must not be read as runtime configuration, startup fallback, or automatic seed data.

When the database has no active workflow version, Symphony should start in setup-required mode and must not listen for tracker issues or schedule agents.

## Context

The project currently has two workflow data paths:

- local split package files (`workflow.yml` and `profiles.yml`)
- SQLite `workflow_versions`

That split creates ambiguous behavior: startup may use file-backed data, database-backed data, or file seed behavior depending on mode and local files. The product direction is simpler: DB is the runtime truth; files are only for future import/export and human-readable backups.

The CLI already no longer accepts a workflow YAML positional argument. This plan finishes the runtime side of that direction.

## Scope

- Remove file-backed runtime workflow source selection from the active runtime path.
- Remove automatic seed-from-local-split-package behavior when the DB has no active workflow version.
- Make an empty workflow database resolve to setup-required state.
- Ensure setup-required state prevents:
  - Linear polling/listening
  - startup terminal workspace cleanup that depends on workflow tracker settings
  - agent scheduling
- Keep the existing structured Settings UI able to create/save the first workflow version.
- Keep split package parsing/export code only where it is needed for future import/export or tests of the parser boundary.
- Update diagnostics and UI copy so they describe DB active workflow or setup-required, not file runtime source.
- Update tests to use fake persistence or explicit DB workflow versions instead of local workflow fixtures for runtime behavior.
- Update docs so `workflow.yml` / `profiles.yml` are described as package files, not runtime fallback or automatic seed inputs.

## Non-Goals

- Do not add a CLI import command.
- Do not automatically import `workflow.yml` or `profiles.yml` on startup.
- Do not remove the split package format itself.
- Do not implement full import/export UI in this plan.
- Do not redesign the Settings forms.
- Do not change CLI flags from 079.

## Acceptance Criteria

- [x] `WorkflowStore.current/0` and related runtime reads never choose local `workflow.yml` / `profiles.yml` as the active runtime source.
- [x] If SQLite has an active workflow version, runtime uses that DB version.
- [x] If SQLite has no active workflow version, runtime returns setup-required.
- [x] Setup-required startup does not poll Linear, run terminal workspace cleanup from Linear state, or start agents.
- [x] Local `workflow.yml` / `profiles.yml` existing in the current directory does not change empty-DB startup behavior.
- [x] Linear diagnostics show setup-required when DB is empty and never report runtime source `file`.
- [x] Settings Workflow tab can still save the first active workflow version into DB.
- [x] Tests no longer rely on local workflow files as runtime fixtures except parser/import-export boundary tests.
- [x] User-facing docs do not describe automatic file seeding or file runtime mode.

## Test Plan

- Update `WorkflowStore` tests for:
  - active DB version selected
  - empty DB returns setup-required
  - local split package does not seed or override empty DB
- Update orchestrator/startup tests for:
  - setup-required does not start polling/listening
  - setup-required skips Linear terminal workspace cleanup
- Update diagnostics tests so setup-required is reported from empty DB.
- Update web tests so Settings can still create the first workflow version.
- Search docs for automatic seed/file runtime wording and remove it from active user-facing docs.
- Run:
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Start at `SymphonyElixir.WorkflowStore`; remove or quarantine code paths that load local files as runtime source.
- Keep parser functions for `workflow.yml` / `profiles.yml` available as library boundaries, but do not call them from runtime startup fallback.
- Runtime source summaries should have only DB and setup-required outcomes.
- Existing local files in the repo may remain as examples/package artifacts, but they should not affect app startup.
- Prefer explicit setup-required errors over fallback behavior. Silent fallback is the behavior this plan is removing.
