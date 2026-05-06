# Task 039: Linear Skill And Docs Restricted Tools Migration

## Status

**Status**: Planned
**Priority**: MEDIUM
**Dependencies**: Tasks 033, 037, 038
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Migrate repo-local Codex skills and user-facing docs away from raw Linear GraphQL and toward `linear_task_read` / `linear_task_update`.

## Background

The repository currently includes a `linear` skill that instructs Codex to use `linear_graphql`. Once restricted task tools exist, skill guidance and docs must stop teaching raw GraphQL as the normal path.

## Scope

- Update `.codex/skills/linear/SKILL.md`.
- Update README references to the Linear skill and dynamic tools.
- Update user guide references if they mention raw GraphQL.
- Link to the Codex/Linear interaction design docs.
- Document that Linear admin/diagnostic operations are backend/operator concerns, not workflow tools.

## Out of Scope

- Implementing the new tools.
- Removing internal Linear client GraphQL usage.
- Changing orchestration behavior.
- Translating all historical completed exec plans.

## Acceptance Criteria

- [ ] The `linear` skill defaults to `linear_task_read` and `linear_task_update`.
- [ ] The `linear` skill no longer teaches raw GraphQL as the normal Codex workflow.
- [ ] README describes restricted Linear task tools accurately.
- [ ] Docs state Codex does not receive Linear API key.
- [ ] Docs link to the refinement and implementation workflow documents.

## Test Cases

- `rg linear_graphql .codex/skills elixir/README.md elixir/docs/user_guide.zh-CN.md` shows no normal workflow instruction to use raw GraphQL.
- `rg linear_task_read .codex/skills elixir/README.md elixir/docs` finds the new tool names.
- Documentation links resolve to existing files.

## Implementation Notes

- Historical completed exec plans may still mention `linear_graphql`; do not rewrite history unless it confuses current guidance.
- Keep skill instructions concise and operational.
- If the new tools are not implemented yet, clearly mark the skill update as future behavior or wait until Task 033 lands.

## Verification

- [ ] `rg linear_task_read .codex/skills elixir/README.md elixir/docs`
- [ ] `rg linear_graphql .codex/skills elixir/README.md elixir/docs/user_guide.zh-CN.md`
- [ ] `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Task 033 defines restricted tool names and payloads.
- Tasks 037 and 038 define the two main workflow behaviors.

## Handoff Notes

This task is intentionally docs/skill only. It should be done after the new tool API is stable enough that skill guidance will not churn.
