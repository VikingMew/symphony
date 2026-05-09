# 059 Project Bootstrap Before Hooks

## Goal

Ensure configured `project.repository_url` bootstrap always runs before custom lifecycle hooks, so repository checkout is not skipped when `hooks.after_create` is also configured.

## Status

Completed.

## Background

The current workspace bootstrap path treats `hooks.after_create` and generated project bootstrap as alternatives:

```elixir
hooks.after_create || Config.generated_after_create_hook()
```

That means a legacy or custom `after_create` hook suppresses the structured `project.repository_url` clone and `project.setup_commands`. In practice, the workflow UI can show a correct target repository while a stale imported `after_create` hook still clones another repository.

The desired contract is ordered composition, not override:

1. create the issue workspace;
2. clone `project.repository_url` when configured;
3. run `project.setup_commands`;
4. run `hooks.after_create` as an additional custom hook.

## Scope

- Change workspace creation to run generated project bootstrap before custom `hooks.after_create`.
- Preserve hook failure behavior: any failing project bootstrap or `after_create` command still aborts workspace creation.
- Ensure the execution order is the same for local and remote worker hosts.
- Update docs to explain that `after_create` augments project bootstrap instead of replacing it.
- Add tests for `project.repository_url` plus `hooks.after_create` together.

## Out of Scope

- Changing `before_run`, `after_run`, or removal hook timing.
- Changing repository URL validation.
- Cleaning existing dirty workspaces; that is covered by plan 058.
- Adding a compatibility switch for the old override behavior.

## Acceptance Criteria

- [x] With both `project.repository_url` and `hooks.after_create`, workspace creation clones the configured repository first.
- [x] The custom `after_create` hook runs after the repository clone and can read files from the cloned repository.
- [x] `project.setup_commands` run before custom `hooks.after_create`.
- [x] The same ordered command sequence is used for remote worker bootstrap.
- [x] Failure in project bootstrap or custom `after_create` still returns a workspace creation error.
- [x] Docs no longer say explicit `hooks.after_create` takes precedence over project bootstrap.
- [x] Relevant tests pass.

## Test Cases

- Local workspace with a fixture git repository and custom `after_create` writes a marker that depends on a cloned file.
- Local workspace with `project.setup_commands` and `hooks.after_create` records command order.
- Remote workspace preparation script contains the generated clone/setup commands before the custom `after_create` hook.
- Existing explicit hook-only workflows without `project.repository_url` still run `after_create`.
- Failing `after_create` still aborts creation after project bootstrap.

## Implementation Notes

- Prefer building an ordered command list in the config/workspace boundary rather than concatenating opaque strings in multiple places.
- Avoid changing `Config.generated_after_create_hook/1` callers unexpectedly unless all call sites are updated.
- This plan should pair naturally with plan 058, but it is independently verifiable.

## Verification

Passed:

- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- make all` progressed through setup, build, format check, lint, and coverage. Coverage ran 273 tests with 0 failures, 2 skipped, and 83.32% total coverage.

Known unrelated blocker:

- `mise exec -- make all` failed at the final Dialyzer step with existing repository warnings in modules such as `persistence.ex`, `orchestrator.ex`, `workflow.ex`, and `workflow_validator.ex`.

## Completion Deviations

Remote bootstrap order is verified at the workspace preparation script level. `make all` is not fully green because Dialyzer currently reports existing project-wide warnings outside this plan.

## Dependencies

- Existing project bootstrap schema.
- Existing workspace hook execution path.
- Plan 058 may later make every start clean, but this plan must still work without it.

## Handoff Notes

The active local database currently contains a workflow version with both a target `project.repository_url` and a stale `hooks.after_create` that clones Symphony. This plan fixes the code-level precedence bug; operators may still need to save a corrected workflow to remove stale project-specific hook commands.
