# Task 029: Linear Workflow State Model

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 022, 023, 026
**Created**: 2026-05-06
**Completed**: 2026-05-06

## Goal

Align Symphony's default Linear workflow with a human-gated agent process that starts from a one-sentence idea, refines it into confirmed requirements, executes implementation and testing, and then waits for human acceptance before merging.

The default state flow is:

`Backlog -> Refining -> Needs Refinement Review -> Ready -> In Progress -> Needs Implementation Review -> Ready to Merge -> Merging -> Done`

## Background

The earlier default workflow treated `Todo` and `In Progress` as the primary active states. That made the start of work ambiguous: a newly discovered task could be picked up before an agent had refined the idea into a concrete requirement and before a human had confirmed the refined scope.

The new model separates agent-owned work states from human-owned gates. Agents work only in active states. Human confirmation happens by moving issues through review states. Rework is represented by moving back to the appropriate actionable state, not by introducing a separate `Rework` state.

## Scope

- Update default tracker active states to:
  - `Refining`
  - `Ready`
  - `In Progress`
  - `Ready to Merge`
  - `Merging`
- Update default terminal states to:
  - `Canceled`
  - `Cancelled`
  - `Duplicate`
  - `Done`
- Rewrite the default `WORKFLOW.md` prompt to describe:
  - idea intake from `Backlog`;
  - refinement in `Refining`;
  - human refinement confirmation in `Needs Refinement Review`;
  - implementation in `Ready` and `In Progress`;
  - human implementation acceptance in `Needs Implementation Review`;
  - merge preparation in `Ready to Merge`;
  - merge execution in `Merging`;
  - completion in `Done`.
- Replace `Todo`-specific dispatch blocking with `Ready`-specific dispatch blocking.
- Remove `Rework` from the default workflow design; return issues to `Ready` or `In Progress` when changes are needed.
- Update diagnostics, tests, README, SPEC, and user documentation to match the new default states.

## Out of Scope

- Creating Linear workflow states through the Linear API.
- Automatically moving issues out of human review states.
- Adding a separate `Rework` state.
- Changing persistence schemas or database migrations.
- Changing worker lease, authentication, or dashboard layout behavior.
- Replacing the existing Linear diagnostics UI beyond state-name alignment.

## Acceptance Criteria

- [x] Default config active states match `Refining`, `Ready`, `In Progress`, `Ready to Merge`, and `Merging`.
- [x] Default config terminal states match `Canceled`, `Cancelled`, `Duplicate`, and `Done`.
- [x] `Needs Refinement Review` and `Needs Implementation Review` are documented as human gates and are not active states.
- [x] `Backlog` is documented as intake only and is not an agent-active state.
- [x] `Ready` replaces `Todo` as the dispatchable implementation state.
- [x] `Rework` is not part of the default model.
- [x] Linear diagnostics expected-state checks use the new active and terminal states.
- [x] Documentation and tests no longer present `Todo`, `Closed`, or `Rework` as default workflow states.

## Test Cases

- Assert default parsed config uses the new active and terminal states.
- Assert admin starter workflow uses the same state lists.
- Assert Linear diagnostics reports configured active and terminal states against available Linear states.
- Assert missing-state diagnostics identifies missing new workflow states.
- Assert a `Ready` issue is blocked by non-terminal dependencies.
- Assert a `Ready` issue with terminal blockers can dispatch.
- Keep full ExUnit coverage passing after workflow prompt and state-list changes.

## Implementation Notes

- Keep the workflow state model in configuration and prompt text rather than adding a hard-coded state machine.
- Treat `Cancelled` and `Canceled` as accepted terminal spellings because Linear teams may use either variant.
- Drop `Closed` from the default terminal list to make `Done` the normal successful completion state.
- The agent-active states are intentionally the only states polled for work. Human review states are excluded so humans own those transitions explicitly.
- Diagnostics should use a single workflow snapshot for both runtime source and parsed config so database-backed workflows cannot report a database source while checking file-backed config.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix compile --warnings-as-errors`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix test --cover`
- [x] `git diff --check`

## Completion Deviations

The diagnostics path was tightened during implementation. `SymphonyElixir.Linear.Diagnostics.run/1` now parses settings from the same `WorkflowStore.current_with_source/0` result used to report runtime source. This was necessary to keep database workflow diagnostics internally consistent.

The coverage configuration was tightened after completion. The default non-database suite now excludes the Repo-backed persistence implementation and generated Ecto schemas from coverage accounting, matching the existing fake-persistence test boundary, and `mix test --cover` reports 88.03% total coverage against an 85% threshold.

## Dependencies

- Task 022 Linear integration diagnostics, because diagnostics display and validate configured workflow states.
- Task 023 workflow runtime source consistency, because the new diagnostics check relies on coherent workflow source reporting.
- Task 026 fake persistence boundary, because state-model tests use fake persistence instead of default database integration.

## Handoff Notes

- Configure Linear with the full state set before using the default workflow in production:
  - `Backlog`
  - `Refining`
  - `Needs Refinement Review`
  - `Ready`
  - `In Progress`
  - `Needs Implementation Review`
  - `Ready to Merge`
  - `Merging`
  - `Done`
  - `Canceled` or `Cancelled`
  - `Duplicate`
- Keep human review states out of `tracker.active_states`.
- If implementation review asks for changes, move the issue back to `In Progress`.
- If refinement review asks for changes, move the issue back to `Refining`.
