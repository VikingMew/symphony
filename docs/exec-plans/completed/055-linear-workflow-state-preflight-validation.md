# 055 Linear Workflow State Preflight Validation

## Goal

Validate workflow state names against the actual Linear team states before Codex runs, so invalid target states fail visibly on the workflow or diagnostics page instead of at runtime inside `linear_task_update`.

## Status

Completed.

## Background

The current Symphony workflow can advertise states such as `Needs Refinement Review`, `Needs Implementation Review`, or `Merging` even when the configured Linear team does not have those states. Codex then follows the generated prompt and calls the restricted Linear task API with an allowed target state. The restricted API correctly rejects the request with `linear_state_not_found`, but by then the run has already consumed an agent attempt and usually leaves another comment on the issue.

This is a configuration problem that should be caught before dispatch. The workflow configuration and Linear project/team state list must agree on every state Symphony may poll, route, or request.

## Scope

- Add a reusable validation path that compares configured Symphony workflow states with the Linear team states returned by diagnostics.
- Validate these configured state groups:
  - `workflow.active_states`;
  - `workflow.terminal_states`;
  - `workflow.human_review_states`;
  - every `workflow.allowed_transitions[].from`;
  - every `workflow.allowed_transitions[].to`;
  - every `workflow.states.<state>.profile` key;
  - every `profiles.<profile>.allowed_updates.target_states`.
- Show missing state names grouped by source so operators can see whether the problem is active polling, human review, transition policy, or profile target states.
- Surface the validation on `/diagnostics/linear`.
- Surface the same validation result from the workflow page after save/activation, or link directly to diagnostics with a clear warning when Linear state validation cannot run inline.
- Keep the validation read-only. It must not create or mutate Linear workflow states.
- Add tests for missing target states such as `Needs Refinement Review` and missing active states such as `Merging`.

## Out of Scope

- Automatically creating Linear states.
- Renaming Linear states.
- Guessing replacements such as `In Review` for `Needs Refinement Review`.
- Allowing Codex to call raw GraphQL or discover state ids directly.
- Changing the restricted Linear task update contract.
- Blocking all workflow saves when Linear is temporarily unavailable.

## Acceptance Criteria

- Linear diagnostics reports an error or warning when any configured workflow state is absent from the Linear team states.
- Missing states are grouped by configuration source, including at least:
  - active states;
  - terminal states;
  - human review states;
  - allowed transitions;
  - profile target states.
- Diagnostics for the known mismatch `Needs Refinement Review` clearly explains that the state is configured by Symphony but missing in Linear.
- Workflow save/activation gives the operator a visible validation result or a clear instruction to run Linear diagnostics before dispatching agents.
- The validation does not require Codex to know the Linear API key.
- Agent dispatch can be guarded or warned when runtime workflow validation has known missing Linear states.
- Tests cover successful validation with all states present.
- Tests cover missing human review and profile target states.
- Tests cover missing active state `Merging`.

## Test Cases

- Given Linear team states include all configured workflow states, diagnostics shows the state-validation probe as successful.
- Given Linear team states omit `Needs Refinement Review`, diagnostics reports it under both human review states and the refinement profile target states when both are configured.
- Given Linear team states omit `Merging`, diagnostics reports it under active states and any transition/profile source that references it.
- Given an allowed transition references a missing state, diagnostics reports the transition path and missing side.
- Saving or activating a workflow that changes target states produces UI feedback pointing to the validation result.
- The validation output is deterministic: missing states are sorted and duplicates are grouped without noisy repetition.
- No token, Authorization header, or raw Linear API payload is rendered or logged.

## Implementation Notes

- Prefer adding this as a new Linear diagnostics probe after the project/team state probe has resolved the available state names.
- Use the existing diagnostics log schema from Task 024:
  - `step`;
  - `status`;
  - `message`;
  - `metadata`.
- Suggested probe name: `workflow_states`.
- Suggested validation output shape:

```elixir
%{
  status: :ok | :warning | :error,
  available: ["Backlog", "Refining", "Ready"],
  missing: %{
    active_states: ["Merging"],
    terminal_states: ["Canceled"],
    human_review_states: ["Needs Refinement Review"],
    transitions: [
      %{from: "Refining", to: "Needs Refinement Review", missing: ["Needs Refinement Review"]}
    ],
    profile_target_states: [
      %{profile: "refinement", states: ["Needs Refinement Review"]}
    ],
    state_routes: []
  }
}
```

- Treat missing states that can break dispatch or task transitions as `:error`.
- If Linear API access is unavailable, report the validation as `:skipped` or `:warning` with an explicit reason, not as a false success.
- Keep the existing restricted task API behavior. This validation is preflight feedback, not a runtime authorization bypass.
- Consider adding a small pure function for state validation so it can be tested without network calls.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/linear_workflow_state_validator_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

Workflow state validation is implemented as a pure validator and surfaced through the existing Linear diagnostics states probe. Workflow save/activation already points operators to Linear diagnostics rather than running inline Linear API validation.

## Dependencies

- Related to Task 024 Linear diagnostics log and refresh visibility.
- Related to Task 029 Linear workflow state model.
- Related to Task 032 workflow profile policy schema.
- Related to Task 033 restricted Linear task tools.
- Related to Task 040 workflow page validate-after-edit.

## Handoff Notes

The motivating failure is a refinement profile that permits `target_state: "Needs Refinement Review"` while the configured Linear team only has states such as `In Review`, `Ready`, and `Refining`. The finished implementation should make that mismatch obvious before any agent run is started.
