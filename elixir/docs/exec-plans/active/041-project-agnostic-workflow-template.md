# Project-Agnostic Workflow Template

## Status

**Status**: Planned

## Goal

Replace the default workflow template guidance that is tied to `openai/symphony`, `elixir/`, `mix`, and `mise` with a project-agnostic template. The template should make repository URL, workspace root, setup command, cleanup command, tracker states, and Codex command explicit placeholders.

## Background

The current sample `WORKFLOW.md` is useful for Symphony self-development, but it is unsafe as a general template because it clones the Symphony repo and runs Elixir-specific setup/cleanup. Operators configuring a Rust or other non-Elixir project should not inherit those commands accidentally.

The immediate need came from configuring a project such as `Claude Code Router Rust`, where the right bootstrap path is project-specific and likely Rust-oriented.

## Scope

- Update user-facing workflow sample docs to use project placeholders instead of Symphony-specific clone/setup.
- Keep the actual repository `elixir/WORKFLOW.md` usable for this repo, but clearly label it as this repo's local workflow rather than a reusable template.
- Add a clean generic sample snippet for:
  - `workspace.root`
  - `hooks.after_create`
  - optional `hooks.before_remove`
  - `tracker.active_states`
  - `tracker.terminal_states`
  - `workflow.states` state-to-profile routing
- Add examples for at least:
  - generic project
  - Rust project
  - Symphony Elixir project

## Out of Scope

- Adding a new config schema for project bootstrap.
- Building UI form fields for repository URL or project type.
- Automatically detecting language/toolchain.

## Acceptance Criteria

- [ ] README and user guide no longer present `openai/symphony` clone as the generic default.
- [ ] Generic sample uses `<your-repo-url>` or equivalent explicit placeholder.
- [ ] Generic sample does not run `cd elixir`, `mix`, or `mise` unless in an Elixir-specific example.
- [ ] Rust sample shows a safe setup path such as `cargo fetch`.
- [ ] Docs explain that `workspace.root` is the Symphony workspace root, not the project repo path.
- [ ] The self-repo `elixir/WORKFLOW.md` remains valid and still works for Symphony development.

## Test Cases

- Docs search:
  - `rg "github.com/openai/symphony" elixir/README.md elixir/docs/user_guide.zh-CN.md`
  - generic docs should only mention it as a Symphony-specific example.
- Docs search:
  - `rg "cd elixir|mix deps.get|workspace.before_remove" elixir/README.md elixir/docs/user_guide.zh-CN.md`
  - generic sample should not contain those commands.
- Existing workflow validation tests still pass.

## Implementation Notes

- Prefer placing the generic template in user guide and README, not replacing `elixir/WORKFLOW.md` wholesale.
- Add a short warning that hooks execute shell commands and should be reviewed before saving.
- Make the state examples use `workflow.states.<state>.profile` and profile-local `name` fields.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `rg "github.com/openai/symphony" elixir/README.md elixir/docs/user_guide.zh-CN.md`
- [ ] `rg "linear_task_read" elixir/README.md elixir/docs/user_guide.zh-CN.md`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 029 established the current state model.
- Task 039 migrated Linear docs to restricted tools.

## Handoff Notes

This plan is documentation/template only. It should not change runtime behavior.
