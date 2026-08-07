# 056 Linear Status Bootstrap Button

## Goal

Provide an operator-controlled button that injects the missing Linear workflow statuses required by the current Symphony workflow into the configured Linear project/team.

The operator should be able to run diagnostics, see which states are missing, click one explicit action, confirm the change, and have Symphony create the missing Linear states needed for the configured workflow.

## Status

Completed.

## Background

Symphony's workflow contract can require states such as `Needs Refinement Review`, `Needs Implementation Review`, or `Merging`. If the configured Linear team does not have those states, Codex can refine or implement a task but fails when requesting the next state through `linear_task_update`.

Task 055 adds preflight validation so this mismatch is visible before runtime. This plan adds the next operator action: a safe bootstrap path that creates the missing Linear statuses from Symphony's configured workflow, instead of asking the operator to manually edit Linear.

This action must be explicit. Symphony should never create or mutate Linear workflow states automatically during polling, dispatch, or Codex execution.

## Scope

- Add a read-only preview of missing Linear states derived from the workflow validation in Task 055.
- Add a button on `/diagnostics/linear` such as `Create missing Linear statuses`.
- Require an explicit confirmation step before mutating Linear.
- Create only states that are required by the current workflow and absent from the configured Linear team.
- Use the Symphony-owned Linear API client on the server side; do not expose the Linear API key to Codex.
- Report which states were created, skipped, or failed.
- Re-run or refresh diagnostics after the mutation so the operator can see the updated state validation.
- Log the action with sanitized metadata.
- Add tests using a mocked Linear client.

## Out of Scope

- Automatically deciding better state names.
- Renaming existing Linear states.
- Deleting Linear states.
- Reordering the entire Linear workflow.
- Editing issue state values directly.
- Letting Codex call raw GraphQL or create Linear states itself.
- Running this action automatically on startup, save, activation, poll, or dispatch.

## Acceptance Criteria

- The diagnostics page shows a disabled or hidden bootstrap button when no required states are missing.
- When required states are missing, the diagnostics page shows the missing states and offers an explicit bootstrap action.
- The operator must confirm before Symphony mutates Linear.
- The server creates only missing states referenced by the current workflow validation.
- Existing states are skipped rather than duplicated.
- The result reports created, skipped, and failed state names.
- After success, diagnostics refreshes or clearly prompts the operator to refresh.
- Linear tokens and Authorization headers never appear in UI or logs.
- The button is unavailable when Linear API configuration is missing or diagnostics cannot identify the target team.
- Tests cover no-op, partial missing states, API failure, and success-refresh behavior.

## Test Cases

- Given all workflow states already exist in Linear, render diagnostics and assert the create button is not actionable.
- Given `Needs Refinement Review` and `Merging` are missing, render diagnostics and assert both are shown in the preview.
- Submit the bootstrap action with confirmation; assert the mocked Linear client receives create requests only for the missing states.
- Submit the bootstrap action twice; assert the second run skips existing states and does not duplicate them.
- Simulate one create failure; assert the result shows partial failure and diagnostics remains in a warning/error state.
- Configure missing Linear token or unresolved team id; assert the action is unavailable with a clear message.
- Capture logs during bootstrap and assert state names and project/team metadata are present while secrets are absent.

## Implementation Notes

- Build on Task 055's workflow-state validation output. The bootstrap input should come from validated missing states, not from arbitrary user-submitted names.
- Prefer one server-side service module, for example `SymphonyElixir.Linear.WorkflowBootstrap`, that receives:
  - runtime workflow config;
  - project/team identity from diagnostics;
  - available Linear states;
  - Linear client module.
- The service should return a structured result:

```elixir
%{
  created: ["Needs Refinement Review", "Merging"],
  skipped: ["Ready"],
  failed: [%{state: "Needs Implementation Review", reason: "..."}]
}
```

- If Linear's API requires status type/category, define a conservative mapping in Symphony:
  - active work states: active/in-progress category where Linear supports it;
  - human review states: unstarted or started category depending on Linear API constraints;
  - terminal states: completed/canceled category where Linear supports it.
- If Linear requires workflow ordering or position, append missing states near semantically related configured states when possible; otherwise append with a deterministic default and report that ordering may need manual adjustment.
- Keep the UI copy direct: this action changes Linear team workflow states.
- Do not let profile prompts mention this action. It is an operator/admin control, not an agent workflow step.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/linear_workflow_bootstrap_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

The button is implemented on Linear diagnostics with browser confirmation and server-side creation through Symphony's Linear client. The real Linear mutation uses `workflowStateCreate`; if Linear's API requires workspace-specific ordering/category fields beyond `teamId`, `name`, and `type`, that can be adjusted in the client without exposing credentials to Codex.

## Dependencies

- Depends on Task 055 Linear workflow state preflight validation.
- Related to Task 024 Linear diagnostics log and refresh visibility.
- Related to Task 029 Linear workflow state model.
- Related to Task 033 restricted Linear task tools.

## Handoff Notes

The motivating case is a Linear team that has `In Review` but not Symphony's configured `Needs Refinement Review`. This plan should let the operator explicitly add the missing Symphony states to Linear after seeing a diagnostics mismatch. It should not silently rewrite the Symphony workflow to use existing Linear state names.
