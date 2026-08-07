# Task 036: Orchestrator Profile Activity Dispatch

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 032, 035
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Change orchestrator dispatch from state-only active issue handling to profile-aware dispatch that reads task activity and classifies current intent before starting Codex.

## Background

State alone is not enough to decide what Codex should do. Human review states can send work back to an agent-work state with comments. When that happens, the latest human comment controls the next task. Orchestrator needs to provide the right profile and activity context to Codex.

## Scope

- Map Linear state to workflow profile using Task 032 policy.
- Fetch or provide recent comments/activity before dispatch.
- Classify intent:
  - new refinement
  - refinement rework
  - new implementation
  - implementation rework
  - merge candidate if configured
- Pass profile and activity summary into prompt generation.
- Stop dispatching human review states.
- Preserve existing active issue de-duplication and retry behavior.

## Out of Scope

- Implementing Linear comment fetching if Task 033 exposes it only inside `linear_task_read`; this task may use a fake activity provider first.
- Dynamic tool implementation.
- Prompt text details.
- Merge workflow completion.

## Acceptance Criteria

- [ ] Issues in `Refining` dispatch with refinement profile.
- [ ] Issues in `Ready` or `In Progress` dispatch with implementation profile.
- [ ] Issues in human review states do not dispatch.
- [ ] If activity shows a human rejection transition, run context marks the intent as rework.
- [ ] Prompt builder receives profile and activity summary.
- [ ] Existing retry/backoff behavior remains intact.

## Test Cases

- Orchestrator dispatches a `Refining` issue as refinement.
- Orchestrator dispatches a `Ready` issue as implementation.
- Orchestrator skips `Needs Refinement Review`.
- Orchestrator classifies `Needs Implementation Review -> In Progress` activity as implementation rework.
- Existing active-run and terminal cleanup tests still pass.

## Implementation Notes

- Add an injectable activity provider so tests do not call real Linear.
- Keep classification logic deterministic and pure where possible.
- Store profile/intent in running entry metadata if useful for dashboard and audit.
- Avoid changing persistence schema unless necessary.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Delivered state-to-profile dispatch, human review state exclusion, worker payload metadata, and prompt guidance that requires reading activity. A separate orchestrator-side activity classifier was not added; review/rejection interpretation happens through `linear_task_read` and profile-specific prompt/tool policy.

## Dependencies

- Task 032 provides state-to-profile policy.
- Task 035 provides profile-aware prompts.

## Handoff Notes

This task should produce observable changes in orchestrator tests even if Linear writes are still mocked.
