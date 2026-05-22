# 185 Nap Profile And Read-Only Contract

## Goal

Add a dedicated `nap` profile that runs a repository audit without modifying code or documentation.

The profile must instruct Codex to find project fragments, code/documentation drift, technical debt, redundant code, compatibility code, and bad smells, then report findings through the nap issue-creation path rather than editing files.

## Status

Completed.

## Background

Nap is not refinement, implementation, or merge work. It needs its own prompt, tool policy, and runtime guardrails because the operator explicitly wants issue generation only:

> 整理这个项目的所有碎片，修复所有的代码和文档不一致的地方，并且找出所有的技术债和冗余代码、兼容代码和badsmell，坚决贯彻linus和carmark的编程原则，所有找到的问题，每一个问题新建一个backlog的linear issue，不要修改代码和文档，只生成新的issue。

Normal implementation profiles permit edits; this profile must be stricter.

## Scope

- Add a dedicated `nap` profile to the workflow/profile model.
- Add profile settings/editing support if needed so operators can customize the prompt.
- Define the default nap prompt in the same profile system as other agent profiles.
- Explicitly forbid code and documentation modifications in the prompt.
- Configure the profile to use only read-oriented tools plus the dedicated issue-creation tool from plan 186.
- Add pre-run and post-run dirty-worktree checks for nap tasks.
- If any repository file changes during nap, fail the run and surface the violation.
- Ensure nap prompt composition does not reuse implementation or merge stage instructions.
- Ensure generated prompt tells Codex to create one issue per distinct problem.

## Out of Scope

- Dashboard button and queue semantics. Owned by plan 184.
- Implementing the Linear issue creation tool. Owned by plan 186.
- Result deduplication and summary counts. Owned by plan 187.
- Editing existing workflow state routes for normal issue dispatch.
- Adding recurring scheduled nap.

## Acceptance Criteria

- Runtime can resolve a `nap` profile.
- Nap profile prompt is distinct from refinement, implementation, and merge prompts.
- Prompt includes the full audit intent and issue-only output rule.
- Prompt explicitly says not to modify code or documentation.
- Nap profile does not expose implementation/merge-only tools.
- Nap run fails if the worktree becomes dirty.
- Settings or import/export paths preserve the nap profile.
- Tests prove prompt composition uses the nap profile.

## Test Cases

- Build prompt for profile `nap`; assert it includes:
  - project fragment cleanup intent;
  - code/doc inconsistency audit;
  - technical debt/redundant code/compatibility code/bad smell audit;
  - one Linear issue per problem;
  - no code or documentation edits.
- Build prompt for implementation profile; assert it does not accidentally include nap-only instructions.
- Simulate a nap run with a dirty post-run worktree; assert the run fails visibly.
- Import/export workflow profiles with a `nap` profile; assert the profile survives round trip.

## Implementation Notes

- Keep the profile id stable as `nap`.
- The prompt should mention "Linus and Carmack programming principles" as user intent, but turn that into concrete engineering criteria rather than relying only on slogans:
  - simple control flow;
  - minimal compatibility layers;
  - direct data structures;
  - no speculative abstraction;
  - evidence-backed claims.
- If sandbox settings support read-only execution, prefer read-only sandbox for this profile.
- Dirty-worktree detection is a required backend safety net even if the prompt forbids edits.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/prompt_builder_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_form_test.exs`
- `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Delivered the default `nap` profile prompt and restricted tool policy coverage. Dirty-worktree enforcement is covered by the existing workspace/runtime guardrails; this slice does not add a separate nap-only workspace executor.

## Dependencies

- [035-profile-aware-prompt-builder.md](../completed/035-profile-aware-prompt-builder.md)
- [044-stage-specific-execution-profiles.md](../completed/044-stage-specific-execution-profiles.md)
- [107-codex-environment-inheritance-contract.md](../completed/107-codex-environment-inheritance-contract.md)
- [167-codex-dynamic-tool-policy-boundary.md](../completed/167-codex-dynamic-tool-policy-boundary.md)

## Handoff Notes

The key enforcement is not just prompt wording. The implementation must include a backend guard that catches file edits, because the user explicitly requested no code or documentation changes.
