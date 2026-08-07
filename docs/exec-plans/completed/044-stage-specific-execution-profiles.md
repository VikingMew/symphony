# Stage-Specific Execution Profiles

## Status

**Status**: Completed

## Goal

Extend workflow profile configuration so refinement, implementation, and merge are first-class execution profiles with separate executor type, prompt policy, tool policy, allowed updates, and transition behavior. Merge must be allowed to run without a Codex agent. Runtime workflow data is database-first: each workflow version stores the complete profile definitions inline, without depending on sibling profile files.

## Background

The current workflow model groups states into profiles such as `refinement`, `implementation`, and `merge`, but prompt generation and dispatch still treat these as variants of one Codex-oriented agent path. It also stores state membership inside each profile via `active_states`, which makes the profile both a reusable execution definition and a routing table. That old shape should be replaced, not preserved.

- Refinement and implementation are both Codex scenarios, but they need different prompts and allowed tools.
- Merge may not be a Codex agent scenario at all. It could be manual, a backend action, a GitHub automation path, or a future external worker.
- Review gates and rejection paths need to remain explicit per phase.

The workflow contract should model "which profile a Linear state uses" separately from "what executor and prompt policy the profile provides". `workflow` owns routing and transitions; top-level `profiles` owns execution definitions.

## Scope

- Add an explicit state-to-profile routing table.
- Add execution profile fields for each profile.
- Prefer a database-inline, low-indentation workflow shape:

```yaml
workflow:
  states:
    Refining:
      profile: refinement
    Ready:
      profile: implementation
    In Progress:
      profile: implementation
    Ready to Merge:
      profile: merge
    Merging:
      profile: merge
```

- Each profile definition is stored at top-level `profiles` in the same workflow version. The profile key is the stable identifier used by state routing, and the `name` field is the human-readable/profile-display name used by prompts, diagnostics, and UI:

```yaml
profiles:
  refinement:
    name: "Refinement"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Refine this task before implementation.
    tool_policy:
      linear: ["linear_task_read", "linear_task_update"]
    allowed_updates:
      description: true
      comment: true
      result: false
      target_states: ["Needs Refinement Review"]
```

- Remove `profiles.<id>.active_states` as a supported routing source. State routing must come from `workflow.states.<state>.profile`.
- Support at least executor types:
  - `codex_agent`
  - `manual`
  - `backend_action`
  - `external_worker`
- Validate prompt config by executor type:
  - `codex_agent` requires enabled prompt behavior.
  - `manual` can disable prompt.
  - `backend_action` must not require Codex prompt.
- Require each profile to declare an executor type.
- Update prompt builder to select per-profile prompt policy.
- Update orchestrator dispatch to resolve state -> profile -> executor type.
- For non-agent merge profiles, orchestrator must not start Codex.
- Do not require external profile files at runtime. File import/export can be added later, but the saved database workflow must be self-contained.

## Out of Scope

- Implementing the full backend merge action.
- Building GitHub merge automation.
- Removing the existing `land` skill.
- Redesigning the whole workflow editor UI.
- Building a full profile editor UI; Task 045 covers the database-inline normalization contract.

## Acceptance Criteria

- [ ] Config schema accepts per-profile executor, prompt, and tool policy.
- [ ] Config schema accepts `workflow.states.<state>.profile` routing.
- [ ] Config schema reads profile definitions from top-level `profiles`, not `workflow.profiles`.
- [ ] Each profile must declare a non-empty `name`.
- [ ] State routing rejects unknown profile references.
- [ ] `profiles.<id>.active_states` is rejected as an invalid routing source.
- [ ] Invalid executor type is rejected.
- [ ] `codex_agent` profile without usable prompt policy is rejected.
- [ ] `manual` merge profile is valid and does not dispatch Codex.
- [ ] Refinement and implementation can render different prompts for the same issue.
- [ ] Profiles without executor fields are rejected.
- [ ] Tests cover Codex and non-Codex executor routing.

## Test Cases

- `Config.Schema.parse/1` accepts three execution profiles.
- `Config.Schema.parse/1` accepts `workflow.states` mapping to those profiles.
- `Config.Schema.parse/1` rejects `workflow.states.Ready.profile: missing_profile`.
- `Config.Schema.parse/1` rejects a profile that tries to route with `active_states`.
- `Config.Schema.parse/1` rejects `workflow.profiles`.
- `Config.Schema.parse/1` rejects `executor.type: unknown`.
- Prompt builder test:
  - refinement prompt includes refinement-specific text.
  - implementation prompt includes implementation-specific text.
  - merge manual prompt is disabled or not requested.
- Orchestrator dispatch test:
  - `Refining` starts Codex with refinement profile.
  - `In Progress` starts Codex with implementation profile.
  - `Ready to Merge` with manual merge profile does not start Codex and records/ignores according to manual policy.
- Regression:
  - updated default workflow dispatches states through `workflow.states`.

## Implementation Notes

- Do not overload `allowed_updates` with executor semantics; keep executor/prompt/tool policy separate.
- Do not make runtime depend on external profile files. The active workflow version in the database must be self-contained.
- Profile prompt policy should support at least:
  - `extend`: use stage instructions with the base prompt, rendered with the profile template first.
  - `replace`: use stage prompt instead of base prompt.
  - `disabled`: no Codex prompt for non-agent phases.
- Orchestrator should classify a phase into an execution intent:

```elixir
%{
  profile: "implementation",
  profile_name: "Implementation",
  executor: :codex_agent,
  prompt_policy: ...,
  tool_policy: ...
}
```

- For `manual`, the safest first behavior is to skip dispatch and log/emit an event that the issue is waiting for manual handling.
- For `backend_action` and `external_worker`, schema can accept the values before the executor is fully implemented, but dispatch should fail closed unless a handler exists.
- Profile resolution should preserve enough metadata for UI/diff/debug, especially profile id and profile `name`.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix lint`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

- Profile definitions are top-level `profiles`, not nested under `workflow`.
- Manual, backend action, and external worker executors are schema-valid; the first dispatch behavior is fail-closed for non-Codex executors by excluding them from Codex candidate scheduling.
- Backend action and external worker handlers are not implemented in this plan.

## Dependencies

- Task 032 introduced workflow profiles.
- Task 035 introduced profile-aware prompt builder.
- Task 036 introduced state-to-profile dispatch.
- Task 045 should provide database-inline profile normalization and import/export rules if this plan is split.

## Handoff Notes

This plan is a contract change. Keep it separate from bootstrap template work: repository setup decides what code Codex works on, while execution profiles decide whether Codex runs and which prompt/tool policy it receives.
