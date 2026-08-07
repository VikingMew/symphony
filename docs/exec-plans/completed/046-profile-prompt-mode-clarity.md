# 046 Profile Prompt Mode Clarity

## Goal

Rename profile prompt composition so workflow authors can tell exactly how a profile prompt combines with the base `WORKFLOW.md` prompt.

The old `prompt.mode: append` name was easy to misread because runtime places the profile template before the base prompt. The configuration contract should use names that describe intent, not implementation order.

## Status

Completed.

## Background

`WORKFLOW.md` is a complete workflow package. Its YAML front matter contains `workflow` plus top-level `profiles`, and the Markdown body after `---` is the base prompt shared by Codex profiles.

Each Codex profile also has a `prompt.template`. The supported modes are:

- `extend`: use profile template together with the base prompt.
- `replace`: use only the profile template.
- `disabled`: non-Codex executor only.

The word `append` was ambiguous because a reader could reasonably expect the profile text to be appended after the base prompt. Runtime prepends the profile template before the base prompt, because stage-specific instructions should be seen first.

## Scope

- Replace the public config name `append` with `extend`.
- Keep the runtime behavior: profile template first, then base prompt.
- Update config schema validation to accept the new public mode and reject ambiguous or legacy names if no compatibility is desired.
- Update default workflow package generation and `elixir/WORKFLOW.md`.
- Update docs that describe profile prompt composition.
- Update tests to verify exact prompt composition order and validation errors.

## Out of Scope

- Changing the location of profile definitions.
- Moving profiles into separate files.
- Changing state-to-profile routing.
- Changing Linear tool policy or allowed update semantics.
- Adding a UI form for every prompt field.

## Acceptance Criteria

- A Codex profile can use:

  ```yaml
  prompt:
    mode: extend
    template: |
      Stage-specific instructions.
  ```

- `extend` renders as:

  ```text
  <profile prompt.template>

  <base prompt body from WORKFLOW.md>
  ```

- `replace` renders only the profile template.
- `disabled` remains valid only for non-Codex executors.
- Codex profiles using `extend` or `replace` must have a non-empty `prompt.template`.
- Workflow examples no longer use `prompt.mode: append`.
- Tests fail if prompt order changes accidentally.

## Test Cases

- Schema accepts `codex_agent + extend + non-empty template`.
- Schema rejects `codex_agent + extend + missing template`.
- Schema accepts `codex_agent + replace + non-empty template`.
- Schema rejects `codex_agent + disabled`.
- Schema accepts `manual + disabled`.
- PromptBuilder with `extend` returns profile template before base prompt.
- PromptBuilder with `replace` excludes base prompt.
- Default workflow package validates with the updated schema.

## Implementation Notes

- The user-facing mode should express policy, not physical placement. `extend` means “include both profile prompt and base prompt.”
- Documentation should explicitly state the render order to avoid another naming ambiguity.
- If the code still contains an internal helper named `append`, rename it during this plan to avoid future confusion.
- Because this project does not require historical compatibility for workflow profile nesting, this plan should not introduce a legacy `append` compatibility path unless a later product decision asks for it.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix test test/symphony_elixir/core_test.exs` passed: 50 tests, 0 failures.
- `mise exec -- mix test` passed: 251 tests, 0 failures, 2 skipped.
- `mise exec -- mix lint` passed: no issues.
- `git diff --check` passed.

## Completion Deviations

Implementation changed the public mode name directly from `append` to `extend`; no compatibility alias was added.

## Dependencies

- Depends on completed profile routing and prompt builder work:
  - `044-stage-specific-execution-profiles.md`
  - `045-database-inline-profile-normalization.md`

## Handoff Notes

When implementing, update the workflow package examples first, then align schema and PromptBuilder. The final public contract should not require readers to know whether the implementation prepends or appends internally.
