# Project Bootstrap Config Schema

## Status

**Status**: Completed
**Completed**: 2026-05-07

## Goal

Add a structured project bootstrap configuration to the workflow schema so repository checkout, setup commands, and cleanup commands are explicit machine-readable fields instead of only free-form shell hooks.

## Background

`hooks.after_create` currently carries multiple meanings:

- clone the target repository
- install dependencies
- trust local tool configs
- run project-specific bootstrap

This makes templates hard to validate and easy to copy incorrectly. A Rust project, Elixir project, and generic shell project need different bootstrap commands, but they all share common concepts: repository URL, branch, checkout depth, setup commands, and cleanup commands.

## Scope

- Add a `project` or `bootstrap` section to `Config.Schema`.
- Suggested shape:

```yaml
project:
  repository_url: "git@github.com:org/repo.git"
  default_branch: "main"
  checkout_depth: 1
  setup_commands:
    - "cargo fetch"
  cleanup_commands: []
```

- Validate repository URL is a non-empty string when provided.
- Validate branch is a non-empty string when provided.
- Validate checkout depth is a positive integer or null.
- Validate setup/cleanup commands are lists of non-empty strings.
- Preserve explicit `hooks.after_create` and `hooks.before_remove` behavior when operators configure them.
- Provide helper functions that can render bootstrap config into hook commands when hooks are omitted.

## Out of Scope

- Removing existing hooks.
- Executing bootstrap commands differently from current hook execution.
- Supporting secrets interpolation beyond existing env behavior.
- Network validation of repository availability.

## Acceptance Criteria

- [x] Existing workflows without `project` or `bootstrap` still parse.
- [x] A workflow with structured project bootstrap parses and validates.
- [x] Invalid setup command list is rejected with clear config error.
- [x] Invalid checkout depth is rejected.
- [x] When structured bootstrap is present and hooks are omitted, workspace creation can still clone/setup using generated commands.
- [x] Explicit hooks continue to take precedence over generated bootstrap commands.
- [x] Tests cover schema parsing and generated hook behavior.

## Test Cases

- `Config.Schema.parse/1` accepts valid project bootstrap.
- `Config.Schema.parse/1` rejects:
  - blank repository URL
  - non-list setup commands
  - blank command entry
  - checkout depth `0`
- Workspace creation test with generated after-create command from bootstrap config.
- Regression test with explicit hooks unchanged.

## Implementation Notes

- Keep shell rendering centralized and simple.
- Avoid composing commands with unescaped user input unless shell escaping is applied.
- Consider whether repository URL should be rendered through a `git clone --depth` command or left as a user-visible generated hook preview first.
- If implementation risk is high, first expose parsed bootstrap config and defer automatic hook rendering to Task 043.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [x] `mise exec -- mix test`
- [x] `git diff --check`

## Completion Deviations

The delivered schema uses the top-level `project` section. Generated hook commands are used only when explicit `hooks.after_create` or `hooks.before_remove` are absent.

## Dependencies

- Task 041 should clarify the desired generic template.
- Existing workspace hook execution must remain stable.

## Handoff Notes

This plan creates the data model. Keep UI work separate so schema behavior can be verified independently.
