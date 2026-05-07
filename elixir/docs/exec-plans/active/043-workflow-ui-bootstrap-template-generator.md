# Workflow UI Bootstrap Template Generator

## Status

**Status**: Planned

## Goal

Add UI support for generating or editing project bootstrap workflow snippets so operators can create a correct `WORKFLOW.md` for a specific repository and toolchain without copying Symphony's self-development hooks.

## Background

The `/workflows` page currently edits raw workflow text. That remains useful, but operators need a safer path for the high-risk fields:

- repository URL
- workspace root
- setup commands
- cleanup commands
- tracker state mapping
- workflow review states
- execution profile mode and prompt behavior for refinement, implementation, and merge

Once workflow validation and project bootstrap schema exist, the UI can guide users toward valid project-specific templates.

## Scope

- Add a lightweight bootstrap/template section to `/workflows`.
- Support at least these template modes:
  - Generic shell project
  - Rust project
  - Elixir project
- Generate or update raw workflow text using chosen values.
- Generate separate execution profile stanzas for refinement, implementation, and merge.
- Let merge be generated as `manual` or backend/non-agent by default when a project does not want a Codex merge agent.
- Show a preview before save.
- Run workflow validation before save using Task 040 validator.
- Preserve manual raw editing.
- Provide clear labels that hook commands execute on worker machines.

## Out of Scope

- Full multi-step onboarding wizard.
- Automatic repository language detection.
- Secret storage UI.
- Validating Git credentials or running `cargo`/`mix` from the UI.

## Acceptance Criteria

- [ ] `/workflows` can generate a generic workflow snippet from repo URL and workspace root.
- [ ] Rust template includes Rust-appropriate setup commands and no Elixir-specific commands.
- [ ] Elixir template can include `mise`/`mix` commands only when that mode is selected.
- [ ] Generated workflow passes validation when required fields are supplied.
- [ ] Generated workflow has distinct prompt/executor config for refinement, implementation, and merge.
- [ ] Merge can be generated without a Codex agent executor.
- [ ] Invalid generated workflow surfaces validation errors before saving.
- [ ] Manual raw editor remains available and unchanged for advanced users.
- [ ] Tests cover template generation and validation failure display.

## Test Cases

- LiveView renders bootstrap template controls on `/workflows`.
- Submitting Rust template values updates raw workflow preview.
- Choosing non-agent merge mode updates the merge profile executor without changing refinement/implementation prompts.
- Saving valid generated Rust workflow creates a workflow version.
- Saving generated workflow with blank repository URL fails validation.
- Existing raw workflow save tests continue to pass.

## Implementation Notes

- Keep the first UI version compact; do not redesign the whole workflow page.
- Avoid nested cards in the LiveView layout.
- Use existing flash and diagnostics notice patterns.
- Consider extracting template generation into a pure module so tests do not depend only on LiveView.
- Generate hook commands from template values only as the execution form for bootstrap; do not treat them as a separate workflow contract once Task 042 is available.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix lint`
- [ ] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workflow_store_fake_persistence_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 040 workflow validation.
- Task 041 generic templates.
- Task 042 structured bootstrap schema.
- Task 044 execution profile schema.

## Handoff Notes

This plan is the operator-facing layer. It should not silently overwrite raw workflow text without a preview or explicit save action.
