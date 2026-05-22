# 189 Agent Continuation Profile Revalidation

## Goal

Fix agent continuation after workflow state changes so a Codex session never continues without a valid executable workflow profile.

The motivating failure is a refinement issue that reaches `Needs Refinement Review`, is manually returned to `Refining`, and then later fails restricted Linear tools with `Workflow profile is unavailable for this Codex session.`

## Status

Completed.

## Background

Symphony supports human review loops. A normal refinement flow is:

1. Codex works an issue in `Refining` with the `refinement` profile.
2. Codex requests `Refining -> Needs Refinement Review`.
3. A human reviews the result.
4. If more work is needed, the human sends the issue back to `Refining` with comments.
5. Symphony should run a new executable refinement context that reads the latest comments before updating the task again.

The current continuation path is weaker than the initial dispatch path. `SymphonyElixir.Orchestrator.DispatchPolicy.candidate_issue?/2` checks active states, human-review states, executable state routing, terminal states, and listening mode before dispatching. By contrast, `SymphonyElixir.AgentRunner.Policy.continue_with_issue?/3` only refreshes the issue and checks whether its state is listed in `tracker.active_states`.

That means a normal turn can continue using an issue snapshot or state boundary that no longer has a valid workflow profile. When the Codex restricted Linear tool executor later calls `Config.workflow_profile_for_state(issue.state)`, the profile can be `nil`, which makes `linear_task_read` or `linear_task_update` fail with `workflow_profile_unavailable`.

This is especially visible after review loops because the issue is intentionally moved out of an agent-work state and then back into one by a human. The fix should treat that state boundary as a dispatch/profile boundary, not as a blind continuation.

## Scope

- Rework the agent continuation decision so it uses the same executable-state contract as initial dispatch.
- Require a refreshed issue to have a non-empty workflow profile before continuing a Codex turn.
- Stop continuation when the refreshed issue is in a human review state, terminal state, non-executable state, or a state with no `workflow.states.<state>.profile` route.
- If the refreshed state is executable but the profile differs from the profile used by the current run, stop the current Codex session and return control to the orchestrator so the next run starts with the correct prompt/profile contract.
- Preserve normal multi-turn continuation when the issue remains in the same executable profile and still needs agent work.
- Add clear runtime logging and persisted event detail for continuation stops, including `reason`, `state`, and `profile` when available.
- Add focused tests for refinement review rejection loops and profile-unavailable prevention.
- Update relevant workflow docs if they imply continuation only depends on `tracker.active_states`.

## Out of Scope

- Changing the Linear workflow model or default state names.
- Automatically moving issues from review states back to work states.
- Changing restricted Linear tool permissions for `refinement`, `implementation`, or `merge`.
- Changing the profile prompt content except where tests need stable profile handoff evidence.
- Adding new UI controls for retrying or manually dispatching a returned issue.

## Acceptance Criteria

- A returned issue in `Refining` after `Needs Refinement Review -> Refining` starts or resumes with the `refinement` profile and can call `linear_task_read`.
- An issue in `Needs Refinement Review` never continues a Codex turn merely because it was recently active.
- `continue_with_issue?` or its replacement rejects refreshed states that are human review states, terminal states, or missing a workflow profile route.
- A profile change across turns stops the current session and lets orchestrator dispatch a new run instead of reusing stale profile context.
- Restricted Linear tools no longer surface `Workflow profile is unavailable for this Codex session` during normal review rejection loops.
- Operator logs or events explain that the run stopped because the refreshed state was not continuable, rather than emitting repeated opaque tool failures.
- Existing dispatch behavior remains unchanged for ordinary active issues in `Refining`, `Ready`, `In Progress`, `Ready to Merge`, and `Merging`.

## Test Cases

- Policy test: refreshed issue in `Refining` with a `refinement` profile and current profile `refinement` returns continue.
- Policy test: refreshed issue in `Needs Refinement Review` returns done with a human-review reason.
- Policy test: refreshed issue in an active state with no `workflow.states` route returns done or a typed stop reason, not continue.
- Policy test: refreshed issue moves from `Refining` to `Ready` or from `implementation` to `merge` profile; the current run stops so orchestrator can create a new profile-scoped run.
- Agent runner test: after a normal turn requests `Needs Refinement Review`, the runner does not immediately start continuation turn 2 for that review state.
- Rejection-loop test: after a human transition back to `Refining`, a later dispatch uses a fresh `refinement` prompt and passes `profile: "refinement"` to dynamic Linear tools.
- Regression test: missing workflow profile produces a clear non-continuable run/event reason before any restricted Linear tool call is attempted.

## Implementation Notes

- Prefer extracting a continuation eligibility function that accepts enough dispatch settings to mirror `DispatchPolicy.candidate_issue?/2` without coupling `AgentRunner.Policy` to the orchestrator process.
- The check should normalize state names through the same path used by dispatch policy.
- Avoid letting `tracker.active_states` be the sole source of truth for continuation. It is a coarse fetch/interest list, not proof that a state is executable in the current profile contract.
- Keep the side effect boundary in `AgentRunner`; the policy should return typed decisions such as `{:continue, issue, profile}`, `{:done, issue, reason}`, or equivalent.
- Treat missing profile as a workflow/runtime contract failure that stops continuation cleanly. Do not paper over it by inventing a default profile.
- The dynamic tool layer should still reject calls without profile as a final guard, but normal agent flow should fail earlier with better context.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/agent_runner/policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator/dispatch_policy_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_test.exs`
- `mise exec -- mix exec_plans.check`
- Manual or fixture-backed evidence from a review rejection loop:
  - `Refining -> Needs Refinement Review` stops the current run.
  - `Needs Refinement Review -> Refining` is later dispatched with `profile: refinement`.
  - no `workflow_profile_unavailable` restricted-tool failure appears in that normal path.

## Completion Deviations

None yet.

## Dependencies

- `037-refinement-workflow-execution.md`
- `142-orchestrator-dispatch-policy-boundary.md`
- `164-agent-runner-sequencing-boundary.md`
- `167-codex-dynamic-tool-policy-boundary.md`

## Handoff Notes

The important behavioral rule is that continuation is not just "issue still active." Continuation is only valid when the refreshed issue is still executable under the same profile context. Human review states and profile transitions are boundaries where the current Codex session should stop and orchestrator should decide the next run from current Linear state.
