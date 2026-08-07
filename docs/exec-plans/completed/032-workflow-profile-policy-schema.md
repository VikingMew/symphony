# Task 032: Workflow Profile Policy Schema

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 029
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Extend `WORKFLOW.md` configuration from active/terminal state lists into an explicit workflow contract with Codex profiles, human review states, allowed transitions, and profile-specific Linear update policy.

## Background

The current workflow model can tell Symphony which Linear states are active and terminal, but it cannot express who may move a task between states, which states are human review gates, or which Codex profile is allowed to update task detail, comments, result metadata, and target states.

The new Codex/Linear design requires:

- refinement profile for task detail refinement;
- implementation profile for code/test/branch work;
- human review states that stop agent dispatch;
- allowed transition policy, including reverse transitions for human rejection.

## Scope

- Add workflow profile schema support in `SymphonyElixir.Config.Schema`.
- Support `workflow.profiles.<name>.active_states`.
- Support `workflow.profiles.<name>.allowed_updates`.
- Support `workflow.human_review_states`.
- Support `workflow.allowed_transitions`.
- Preserve backward compatibility with existing `tracker.active_states` and `tracker.terminal_states`.
- Expose parsed workflow policy through `Config` helper functions.
- Document the new YAML shape in README or config docs.

## Out of Scope

- Changing dispatch behavior.
- Implementing new Linear tools.
- Changing Codex prompts.
- Removing `linear_graphql`.
- Building workflow UI structured forms for the new fields.

## Acceptance Criteria

- [ ] Existing workflow files without `workflow.profiles` still parse and validate.
- [ ] A workflow with `refinement` and `implementation` profiles parses into stable structs/maps.
- [ ] Invalid profile names or malformed active states are rejected with clear schema errors.
- [ ] Invalid transition entries are rejected.
- [ ] Allowed update policy can express `description`, `comment`, `result`, and `target_states`.
- [ ] Human review states are parsed separately from active and terminal states.
- [ ] Defaults reproduce the current gated workflow behavior when omitted.

## Test Cases

- Parse current default `WORKFLOW.md`.
- Parse a workflow with:
  - `refinement.active_states: ["Refining"]`
  - `implementation.active_states: ["Ready", "In Progress"]`
  - review states
  - bidirectional human rejection transitions.
- Reject a transition missing `from` or `to`.
- Reject a profile with `target_states` not represented as a list of strings.
- Assert helper functions return profile for a given state.

## Implementation Notes

- Keep the first implementation map-based if adding many embedded schemas would be noisy.
- Normalize state names consistently with existing state normalization.
- Provide a default policy derived from the current default states:
  - `Refining -> Needs Refinement Review`
  - `Ready -> In Progress`
  - `In Progress -> Needs Implementation Review`
- Do not add a raw GraphQL enablement switch.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Implemented as a normalized `workflow` map on `Config.Schema` rather than a dedicated embedded schema module. This keeps config compatibility simple while still validating profiles, review states, transitions, and tool policy.

## Dependencies

- Task 029 established the current gated Linear state model.

## Handoff Notes

This task only makes the policy representable and validated. Dispatch, prompt routing, and tool enforcement should be delivered by later tasks.
