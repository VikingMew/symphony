# Task 033: Restricted Linear Task Read Update Tools

## Status

**Status**: Planned
**Priority**: HIGH
**Dependencies**: Task 032
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Replace Codex-facing raw Linear GraphQL access with two restricted dynamic tools:

- `linear_task_read`
- `linear_task_update`

The tools must let Codex read current task context and submit controlled updates without seeing the Linear API key or sending arbitrary GraphQL.

## Background

The existing `linear_graphql` dynamic tool is too broad. It does not reveal the API key to Codex, but it lets Codex use Symphony's Linear credential for arbitrary GraphQL operations. The new design keeps GraphQL behind the Symphony backend and exposes only task-scoped, policy-checked operations.

## Scope

- Add `linear_task_read` dynamic tool.
- Add `linear_task_update` dynamic tool.
- Ensure both tools are scoped to the current run issue.
- Return issue detail, recent comments/activity, state changes, profile, and allowed updates from `linear_task_read`.
- Support controlled description/comment/result/target-state updates through `linear_task_update`.
- Enforce profile allowed update policy from Task 032.
- Stop exposing `linear_graphql` in default `DynamicTool.tool_specs/0`.
- Keep existing Linear client boundaries testable with fake clients.

## Out of Scope

- Orchestrator profile dispatch.
- Prompt changes.
- Real Linear end-to-end verification.
- UI for tool policy editing.
- Providing an operator raw GraphQL endpoint.

## Acceptance Criteria

- [ ] Codex-visible tool specs include `linear_task_read` and `linear_task_update`.
- [ ] Codex-visible tool specs do not include `linear_graphql`.
- [ ] `linear_task_read` returns issue, activity, and workflow allowed updates for the current issue.
- [ ] `linear_task_update` can add a comment to the current issue.
- [ ] `linear_task_update` can update description only when the current profile allows it.
- [ ] `linear_task_update` can submit implementation result only when the current profile allows it.
- [ ] `linear_task_update` rejects updates for any issue other than the current run issue.
- [ ] Tool responses never include token or Authorization header values.

## Test Cases

- Tool spec test: assert only restricted Linear tools are exposed.
- Read test: fake Linear client returns issue + comments + state changes; assert shaped response.
- Update test: refinement profile permits description and comment.
- Update test: implementation profile rejects description but accepts result/comment.
- Transition test: target state not in policy is rejected.
- Security test: arbitrary issue id in input is ignored or rejected.
- Regression test: unsupported dynamic tool still returns a stable failure response.

## Implementation Notes

- `linear_task_read` should be the mandatory first tool for Codex workflows. It should return recent comments by default.
- `linear_task_update` should accept a single payload and execute only after validation.
- If Linear does not provide transactional semantics, return and audit partial success explicitly.
- Keep raw GraphQL code only as an internal Linear client implementation detail, not as a Codex dynamic tool.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 032 supplies profile allowed update policy.

## Handoff Notes

This task should produce visible behavior even before orchestrator routing changes: any app-server session should see the new restricted tool surface.
