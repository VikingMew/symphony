# 167 Codex Dynamic Tool Policy Boundary

## Goal

Split `SymphonyElixir.Codex.DynamicTool` into tool argument/policy validation and side-effect execution boundaries.

## Status

Completed.

## Background

`Codex.DynamicTool` still combines several responsibilities:

- tool spec declaration;
- read/update argument normalization;
- workflow profile update-policy validation;
- implementation branch pushed checks;
- Linear issue updates/comments/state lookups;
- reference link extraction/deduplication;
- response JSON encoding and error payload formatting.

This is security-sensitive code because it constrains what the agent may update. The current shape makes it too easy to mix policy changes with side-effect changes.

## Scope

- Extract argument normalization and update-policy validation into a pure counted module.
- Keep Linear side effects behind the existing tool execution boundary.
- Add direct tests for allowed update fields, target state restrictions, required result/comment behavior, implementation completion branch checks, and reference link extraction.
- Keep public tool names and response shapes unchanged.

## Out of Scope

- Adding new dynamic tools.
- Changing allowed update policy semantics.
- Changing Linear GraphQL mutations.
- Changing app-server tool request handling.

## Acceptance Criteria

- Policy validation can be tested without GraphQL or Git.
- Side-effect execution paths call a clear policy result before mutating Linear.
- Error payloads remain stable.
- The module becomes easier to count toward coverage or remove from broad risk categories.

## Verification

- `mix test test/symphony_elixir/dynamic_tool_test.exs`
- Focused tests for the extracted dynamic tool policy module
- `rg -n "normalize_update_arguments|validate_update_policy|validate_target_state_allowed|validate_implementation_branch_pushed|reference_link_candidates|tool_error_payload" lib test`
- `mix exec_plans.check`

## Completion Deviations

Extracted update argument normalization, update policy validation, implementation completion target classification, and reference link extraction into `SymphonyElixir.Codex.DynamicTool.Policy`. Linear/Git side effects remain in `DynamicTool`.
