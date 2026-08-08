# 241 Single source for config defaults

## Goal

Stop three-way default-value drift between Config.Schema, setup sentinel, and WorkflowForm; make
`Config.Schema` the only typed defaults owner.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md M1. The spec/Schema workspace default is
`<system-temp>/symphony_workspaces` and max-concurrency `10`
(config/schema.ex:88-100, 199-211, 574-597; docs/spec-workflow-config.md:110, 312-318), but:
- empty-form fallbacks hard-code `/tmp/symphony-workspaces` (different separator) and `1`
  (workflow_form.ex:20-64, 404-413; web/admin/project_settings.ex:148-159);
- `setup_required_workflow/1` hard-codes concurrency `1` and omits workspace
  (workflow.ex:72-99);
- `normalized_display_config/1` calls `Schema.parse/1` but only re-assembles workflow/profiles, so
  nested Schema defaults never project into the form (config/runtime_resolver.ex:8, 55-62).
On macOS `/tmp` and `System.tmp_dir!()` often differ, so the first save persists the UI fallback
into the DB. Violates Carmack "minimize things that can go wrong" (one fact, many
representations) and Linus "remove complexity".

## Scope

- `Config.Schema` becomes the single source of typed defaults + external-config projection.
- `WorkflowForm` / `ProjectSettings` / `normalized_display_config` format Schema output only; remove
  hard-coded `/tmp/symphony-workspaces` and the separate `1` fallback.
- If first-run concurrency `1` is an intentional product policy, extract it as a NAMED
  first-run policy (documented + tested), not a disguised Schema default.

## Out of Scope

- Splitting the Schema module itself (K4 keep-as-is).
- Changing the actual first-run experience beyond removing the drift.

## Acceptance Criteria

- Empty form produces the Schema default (`<system-temp>/symphony_workspaces`, concurrency 10)
  or the explicitly named first-run policy — never a bare literal.
- `grep '/tmp/symphony-workspaces'` in lib/ -> zero hits.
- First save persists the Schema default, not a UI fallback literal.

## Test Cases

- Form-empty projection test per settings surface (workflow form, project settings).
- Schema default unit test.
- Existing settings/form suites stay green.

## Implementation Notes

Add one `Config.Schema.defaults/0` (or equivalent) consumed by both form layers; keep the
display/formatting in the form modules.

## Dependencies

- None.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

