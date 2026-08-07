# Task 038: Implementation Workflow Execution

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 032, 033, 034, 035, 036
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Deliver the implementation Codex workflow end to end: pull a confirmed task, prepare workspace, test baseline, implement, verify, push branch, comment result, and request `Needs Implementation Review`.

## Background

After human requirement confirmation, Codex should handle code implementation and verification but must stop before human acceptance. If humans reject the implementation, Codex must read the latest comment and perform focused rework.

## Scope

- Make implementation profile run behavior operational.
- Ensure implementation prompt requires task read, test/code/verify/push/comment/transition.
- Record validation results and branch/commit metadata.
- Submit result/comment/target state through `linear_task_update`.
- Enforce `Ready -> In Progress` and `In Progress -> Needs Implementation Review` Codex transitions.
- Support returned implementation work from `Needs Implementation Review -> In Progress`.
- Add tests using fake workspace/git/tool boundaries where practical.

## Out of Scope

- Real GitHub PR creation unless existing code already supports it.
- Merge workflow.
- Human acceptance UI.
- Real Linear E2E.

## Acceptance Criteria

- [ ] A `Ready` issue dispatches implementation profile.
- [ ] Implementation run can move or request move to `In Progress`.
- [ ] Validation command results are captured in run metadata or comment payload.
- [ ] Branch and commit metadata are included in `linear_task_update` result.
- [ ] Successful implementation requests `Needs Implementation Review`.
- [ ] Returned implementation work uses latest human comment as controlling input.
- [ ] Failure paths do not silently transition forward.

## Test Cases

- Happy path with fake workspace and fake git push result.
- Rework path with latest human comment.
- Verification failure path: comment/result records failure, no transition to review.
- Push failure path: no transition to review.
- Policy rejection: implementation cannot update description by default.

## Implementation Notes

- Use existing workspace and hook code; do not invent a second workspace manager.
- Keep branch naming compatible with Linear `branchName`.
- Avoid destructive git commands.
- Tests should avoid real network and real remote git where possible.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Delivered implementation as the default `Ready`/`In Progress` profile contract enforced by prompts and restricted task updates. Branch/PR specifics remain produced by the existing Codex workflow and skills, then passed through `result`/`references`.

## Dependencies

- Task 034 should remove secret env before implementation Codex runs.
- Task 032/033/035/036 provide policy, tools, prompt, and dispatch.

## Handoff Notes

This task validates the second Codex scenario independently from refinement. It should not mark human acceptance states as completed.
