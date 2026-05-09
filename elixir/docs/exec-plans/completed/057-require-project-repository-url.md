# 057 Require Project Repository URL

## Goal

Treat a missing `project.repository_url` as an invalid runtime setting so Symphony does not poll Linear, create workspaces, or start Codex work against an implicit or hard-coded repository.

## Status

Completed.

## Background

The workflow already has structured project bootstrap fields, but the runtime still allows a workflow with no `project.repository_url` to validate. That means a stale hard-coded hook, checked-in sample, or empty UI field can let Symphony begin work even though the actual project source has not been configured.

The desired contract is stricter: repository source is required configuration. If it is absent, the setting is failed and no work should start.

## Scope

- Make runtime config validation fail when `project.repository_url` is missing or blank.
- Ensure the orchestrator treats that failure as a configuration error and does not fetch candidate issues.
- Move the checked-in `WORKFLOW.md` bootstrap from hard-coded hooks to explicit `project` configuration.
- Update tests and docs to describe the explicit repository requirement.
- Verify the whole test suite and coverage remain at or above 80%.

## Out of Scope

- Adding repository URL discovery.
- Supporting legacy hook-only repository checkout as a valid runtime mode.
- Changing Linear workflow state validation.

## Acceptance Criteria

- [x] `Config.validate!/0` returns a clear error when `project.repository_url` is absent.
- [x] The orchestrator does not call Linear candidate polling when the repository URL is absent.
- [x] The checked-in `WORKFLOW.md` no longer contains a hard-coded `hooks.after_create` clone.
- [x] Documentation says repository URL is required before runtime work can start.
- [x] Full tests pass.
- [x] Coverage is at least 80%.

## Test Cases

- Missing project repository URL fails config validation.
- Missing project repository URL prevents orchestrator polling.
- Explicit project repository URL still generates the expected checkout/setup hook.
- Checked-in `WORKFLOW.md` parses with an explicit `project.repository_url`.

## Implementation Notes

- Keep hook execution behavior unchanged for explicit hook fields, but do not allow hooks to satisfy the project repository requirement.
- Reuse the existing config validation path so dashboard validation and orchestrator dispatch share the same failure.

## Verification

- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix test --cover`

## Completion Deviations

The coverage gate was adjusted from 85% to 80% to match the requested project policy. The measured
total coverage after the change is 83.27%.

## Dependencies

- Existing project bootstrap schema from plan 042.
- Existing orchestrator config validation gate.

## Handoff Notes

The runtime now fails config validation with `:missing_project_repository_url`; startup can still
create the orchestrator process, but dispatch and Linear polling are blocked until the repository URL
is configured.
