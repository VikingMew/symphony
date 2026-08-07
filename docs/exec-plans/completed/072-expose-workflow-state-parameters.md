# 072 Expose Workflow State Parameters

## Goal

Remove hardcoded workflow state names from runtime defaults and expose the
state model as explicit workflow configuration that can be imported, edited,
validated, exported, and used consistently by the orchestrator and Codex
profiles.

## Status

Completed.

## Background

The implementation review state was renamed from `Needs Implementation Review`
to `In Review` in the operator workflow, but old state names still appeared in
runtime defaults, generated workflow templates, tests, and documentation. The
important issue is not just that one string was stale; Symphony currently keeps
state names in multiple places:

- workflow state routing;
- human review states;
- allowed transitions;
- profile `allowed_updates.target_states`;
- generated default workflow documents;
- schema fallback defaults;
- tests and diagnostics fixtures.

That creates a drift risk. Operators can edit a workflow in the UI, while an
unconfigured or newly bootstrapped runtime can still fall back to a different
hardcoded state contract.

## Scope

- Make workflow state names a single explicit configuration surface.
- Ensure `human_review_states`, `allowed_transitions`, routed `states`, and
  profile `allowed_updates.target_states` are loaded from the same workflow
  configuration source.
- Remove duplicated hardcoded review-state defaults from `Config.Schema` and
  `Workflow`.
- Keep code-level defaults limited to a minimal, project-agnostic template used
  only when no persisted/imported workflow exists.
- Update the workflow page so these parameters are visible and editable as
  structured fields, not hidden YAML-only behavior.
- Validate that all referenced state names exist in the configured Linear team
  states when diagnostics data is available.
- Update docs and tests so the canonical implementation review state is
  configurable and the sample workflow uses `In Review`.

## Out of Scope

- Migrating historical completed execplan text.
- Automatically rewriting existing immutable workflow versions in the
  database.
- Creating Linear workflow states automatically; that remains covered by the
  Linear status bootstrap work.
- Changing the refinement review state name unless the configured workflow
  says so.

## Acceptance Criteria

- A fresh runtime no longer has separate hardcoded copies of review state names
  in both `Workflow` and `Config.Schema`.
- The workflow editor exposes:
  - routed state names and assigned profiles;
  - human review states;
  - allowed transitions;
  - profile allowed target states.
- Saving or importing a workflow validates that profile target states,
  human review states, and transition endpoints are internally consistent.
- Linear diagnostics report any configured state that does not exist in the
  selected Linear team.
- Existing active database workflow versions are not silently rewritten; docs
  explain that operators must save/import a new workflow version to change the
  active contract.
- Tests cover the new configuration path and the `In Review` sample flow.

## Test Cases

- Load an imported workflow with a different implementation review state and
  assert prompts, dynamic tools, and orchestrator routing use that configured
  name.
- Reject or flag a workflow whose `allowed_updates.target_states` references a
  state absent from routed states, human review states, terminal states, or
  Linear diagnostics state names.
- Confirm a persisted active workflow version takes precedence over the
  built-in template.
- Confirm completed historical execplan documents are not part of runtime
  validation.

## Implementation Notes

- Prefer one normalization path for workflow policy and profiles. Avoid keeping
  two hand-maintained default maps with state-name strings.
- Treat `In Review` as sample data, not as a new hardcoded business rule.
- The UI should write the same stored workflow document that import/export
  uses.
- When an existing database workflow still contains the old state, surface that
  as active workflow configuration, not as code behavior.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/web_fake_persistence_test.exs` passed: 74 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/linear_workflow_state_validator_test.exs test/symphony_elixir/linear_diagnostics_test.exs test/symphony_elixir/dynamic_tool_test.exs` passed: 21 tests, 0 failures.
- `mise exec -- mix lint` passed.
- `mise exec -- mix test` passed: 295 tests, 0 failures, 2 skipped.

## Completion Deviations

- The built-in sample state names were not renamed as part of this plan. Per
  implementation feedback, the important behavior is that the workflow page can
  edit and persist the state contract. The sample remains sample data.
- The workflow editor now supports adding/editing transition rows, but it does
  not yet support deleting routed states or profiles as separate entities. Blank
  transition rows are ignored on save.
- Validation checks profile target states for profiles that are actually used by
  routed states or transitions. This avoids hidden default profiles making a
  reduced workflow impossible to save.

## Dependencies

- Existing workflow import/export and persistence model.
- Existing workflow editor structured-field work.
- Existing Linear diagnostics state validation.

## Handoff Notes

The immediate bug is visible as stale `Needs Implementation Review` strings,
but the durable fix is to make the active workflow contract the source of
truth. If old names remain only in completed execplans, they are historical
records and should not affect runtime behavior.
