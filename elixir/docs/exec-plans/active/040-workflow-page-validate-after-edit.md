# Workflow Page Validate After Edit

## Status

**Status**: Planned

## Goal

When an operator edits workflow content in the `/workflows` page, Symphony should validate the submitted workflow before saving or activating it. Invalid YAML, invalid config schema, invalid workflow policy, and semantic config errors should be shown in the UI and must not replace the active runtime workflow.

## Background

The workflow page currently accepts raw `WORKFLOW.md` content through `save_raw_workflow`. The persistence import path parses the Markdown front matter, but the operator experience needs an explicit validity check aligned with runtime behavior:

- YAML/front matter must parse.
- The config must pass `Config.Schema.parse/1`.
- Semantic validation must catch unsupported tracker kind, missing Linear project slug/token when applicable, malformed workflow profile policy, and unsafe runtime settings.
- Workflow execution profiles must be valid: each phase has a supported executor, prompt behavior, tool policy, allowed updates, and target states.
- A bad edit must not become the active workflow or break the current orchestrator runtime.

This is more important now that workflow policy includes profiles, review states, allowed transitions, and restricted Linear tool policy.

## Scope

- Add a workflow validation path that can validate raw workflow Markdown without permanently changing the runtime workflow source.
- Use the same parser and config schema/semantic checks as runtime wherever possible.
- Validate on `/workflows` save before `Persistence.import_workflow/3` is called.
- Validate on workflow activation before `Persistence.activate_workflow_version/1` changes the active version.
- Show actionable validation errors in the workflow page UI.
- Preserve the last known good active workflow if validation fails.
- Add tests for valid save, invalid YAML, invalid schema, invalid semantic config, invalid workflow policy, and invalid activation.

## Out of Scope

- Building a full YAML editor with inline lint markers.
- Validating external services by making network calls to Linear or GitHub.
- Rewriting stored historical invalid workflow versions unless they are being activated.
- Changing dashboard layout beyond the minimum error display needed for validation feedback.

## Acceptance Criteria

- [ ] Saving a valid workflow from `/workflows` succeeds and shows a success message.
- [ ] Saving malformed YAML fails with a visible error and does not import a new workflow version.
- [ ] Saving schema-invalid config fails with the same class of error `Config.settings!/0` would raise.
- [ ] Saving semantically invalid config fails before activation.
- [ ] Saving malformed top-level `profiles`, `workflow.states`, `human_review_states`, or `allowed_transitions` fails with a visible error.
- [ ] Saving malformed execution profile config fails with a visible error, including unsupported executor type or missing prompt config where required.
- [ ] Activating an existing invalid workflow version fails and leaves the previous active version unchanged.
- [ ] The page preserves the submitted raw text after a failed save so the operator can fix it.
- [ ] Existing file-based runtime behavior remains unchanged.

## Test Cases

- LiveView `/workflows` save with a valid workflow:
  - submit raw workflow
  - assert flash success
  - assert persistence import happened
- LiveView `/workflows` save with malformed YAML:
  - submit raw workflow
  - assert visible validation error
  - assert no import call
- LiveView `/workflows` save with invalid config type:
  - example: `polling.interval_ms: "bad"`
  - assert visible validation error includes field context
- LiveView `/workflows` save with invalid workflow policy:
  - example: `workflow.allowed_transitions: [{from: Ready, to: Done, actor: robot}]`
  - assert visible validation error includes `workflow.allowed_transitions.actor`
- LiveView `/workflows` save with invalid execution profile:
  - example: `profiles.merge.executor: codex_agent` with no merge prompt policy when required, or an unknown executor
  - assert visible validation error includes executor/profile context
- Activation validation:
  - create/import one valid active version
  - attempt to activate an invalid version
  - assert active version remains the valid one
- Regression:
  - existing workflow store fake persistence tests continue to pass.

## Implementation Notes

- Prefer adding a small validator module, for example `SymphonyElixir.WorkflowValidator`, so Web UI, persistence activation, and future CLI flows share one contract.
- The validator should return stable tuples such as:

```elixir
{:ok, %{workflow: loaded_workflow, settings: settings}}
{:error, {:workflow_validation_failed, message}}
```

- Validation should likely compose:
  - `Workflow.parse_content/1`
  - `Config.Schema.parse/1`
  - semantic checks equivalent to `Config.validate!/0` without reading `Workflow.current/0`
- If current semantic validation lives only in `Config.validate!/0`, extract an internal/public helper that accepts parsed settings.
- Avoid mutating `Application` workflow source or calling `WorkflowStore.force_reload/0` until validation succeeds.
- For activation, validate `WorkflowVersion.raw_workflow_md` or exported markdown before setting it active.
- Use existing admin flash/notice patterns in `AdminLive`.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix lint`
- [ ] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workflow_store_fake_persistence_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 032 added workflow profile policy schema validation.
- Task 044 should define stage-specific executor and prompt policy.
- Task 017-020 established database/file workflow source behavior.

## Handoff Notes

This plan should produce a visible operator-facing change: a bad workflow edit should fail in the `/workflows` UI before it can affect runtime. Keep the validator independent enough that future CLI or API workflow writes can reuse it.
