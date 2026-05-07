# Task 037: Refinement Workflow Execution

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 032, 033, 035, 036
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Deliver the refinement Codex workflow end to end: pull a `Refining` task, read detail/activity, update task detail, comment, and request `Needs Refinement Review`.

## Background

The product workflow starts from a rough task or one-sentence idea. Codex should refine it into a concrete, reviewable task description, then stop for human confirmation. This must support rejection loops where humans send the task back to `Refining` with comments.

## Scope

- Make refinement profile run behavior operational.
- Ensure `linear_task_read` is available and required in the refinement prompt.
- Ensure `linear_task_update` supports description + comment + target state for refinement.
- Enforce `Refining -> Needs Refinement Review` as the Codex-owned transition.
- Require recent comments/activity to be read before updating returned tasks.
- Add tests using fake Linear/tool clients.
- Update docs if final behavior differs from design docs.

## Out of Scope

- Implementation coding workflow.
- Git branch push behavior.
- Human UI to approve `Needs Refinement Review -> Ready`.
- Real Linear E2E.

## Acceptance Criteria

- [ ] A `Refining` issue can run through refinement with fake Linear tools.
- [ ] The issue description update is requested through `linear_task_update`.
- [ ] A `[codex]` comment is requested through `linear_task_update`.
- [ ] The target state is `Needs Refinement Review`.
- [ ] A returned issue uses the latest human comment as controlling input.
- [ ] Codex cannot request `Ready` directly from refinement profile.
- [ ] Failure to read activity prevents treating a returned task as a normal new task.

## Test Cases

- Refinement happy path: description + comment + transition.
- Rework path: activity contains human comment and state change back to `Refining`; prompt/update references comment id.
- Policy rejection: target state `Ready` is rejected.
- Missing activity for rework returns a blocked or failure result.

## Implementation Notes

- It may be easiest to test this at the dynamic tool/prompt/orchestrator boundary with fake app-server messages.
- Keep actual Codex language-model behavior out of unit tests; verify protocol messages and tool calls.
- If a single `linear_task_update` cannot be atomic, record partial update behavior clearly.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Delivered refinement as a profile contract enforced by prompts and `linear_task_update` policy rather than a separate refinement executor. Codex must read task activity, may update description/comment, and can only request `Needs Refinement Review` from the refinement profile.

## Dependencies

- Task 032 workflow policy.
- Task 033 restricted Linear tools.
- Task 035 profile prompt.
- Task 036 profile dispatch.

## Handoff Notes

The outcome should be observable without code modification or git push. This task validates the first Codex scenario independently.
