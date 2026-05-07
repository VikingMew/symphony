# Task 035: Profile Aware Prompt Builder

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 032, 033
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Generate Codex prompts by workflow profile so refinement, implementation, and merge work have distinct instructions, required Linear tool usage, and review rejection behavior.

## Background

A single generic prompt cannot safely cover requirement refinement, code implementation, testing, branch push, and merge. The new workflow design has at least two Codex scenarios: refinement Codex and implementation Codex. Prompt generation should reflect those different responsibilities and tool policies.

## Scope

- Add profile-aware prompt construction in `PromptBuilder`.
- Include a mandatory instruction to call `linear_task_read` before acting.
- Include rejection handling guidance based on recent human comments.
- Add a refinement prompt path.
- Add an implementation prompt path.
- Keep the existing prompt template behavior for backward compatibility.
- Expose tests that assert profile-specific prompt content.

## Out of Scope

- Orchestrator profile dispatch.
- Implementing the new dynamic tools.
- Merge automation prompt beyond a placeholder if no merge profile is implemented yet.
- UI prompt editor changes.

## Acceptance Criteria

- [ ] Refinement prompt tells Codex to read task detail/activity, update task detail, comment, and request `Needs Refinement Review`.
- [ ] Implementation prompt tells Codex to read task detail/activity, prepare workspace, test, code, verify, push branch, comment, and request `Needs Implementation Review`.
- [ ] Both prompts state latest human comment controls returned-from-review work.
- [ ] Both prompts prohibit raw Linear GraphQL.
- [ ] Existing custom prompt template behavior remains supported.
- [ ] Tests cover prompt selection by profile.

## Test Cases

- Build refinement prompt and assert it includes `linear_task_read`, `linear_task_update`, and `Needs Refinement Review`.
- Build implementation prompt and assert it includes validation, branch push, and `Needs Implementation Review`.
- Build prompt for returned-from-review metadata and assert latest human comment is referenced.
- Existing prompt builder tests still pass.

## Implementation Notes

- Keep profile-specific text small and deterministic.
- Do not include secrets or token values in prompt context.
- Treat comments/activity as summarized context if the raw payload is large.
- If no profile is known, fall back to current behavior but include safe Linear tool guidance.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Implemented profile-aware prompt contracts as a generated prefix around the existing workflow prompt template. Existing custom prompt rendering stays intact when no profile is provided.

## Dependencies

- Task 032 defines profiles.
- Task 033 defines the restricted Linear tool names prompts should reference.

## Handoff Notes

Prompt routing does not need to dispatch different issues yet. It only needs to make profile-specific prompt generation available and tested.
