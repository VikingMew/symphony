# Project Bootstrap Config Schema

## Status

**Status**: Planned

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

- [ ] Existing workflows without `project` or `bootstrap` still parse.
- [ ] A workflow with structured project bootstrap parses and validates.
- [ ] Invalid setup command list is rejected with clear config error.
- [ ] Invalid checkout depth is rejected.
- [ ] When structured bootstrap is present and hooks are omitted, workspace creation can still clone/setup using generated commands.
- [ ] Explicit hooks continue to take precedence over generated bootstrap commands.
- [ ] Tests cover schema parsing and generated hook behavior.

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

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix lint`
- [ ] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 041 should clarify the desired generic template.
- Existing workspace hook execution must remain stable.

## Handoff Notes

This plan creates the data model. Keep UI work separate so schema behavior can be verified independently.
