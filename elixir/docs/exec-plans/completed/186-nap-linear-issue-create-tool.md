# 186 Nap Linear Issue Create Tool

## Goal

Add a restricted Symphony-managed tool or backend action that lets the `nap` profile create new Linear issues in the configured backlog state.

This is separate from `linear_task_update`, which is scoped to updating the current run issue.

## Status

Completed.

## Background

Nap output is not a comment on one existing task. It needs to create new backlog issues, one per discovered problem. Exposing raw Linear GraphQL to Codex would violate the existing restricted-tool contract, so issue creation must be mediated by Symphony.

The user said `lbacklog`; implementation should treat this as the configured Linear backlog state, defaulting to `Backlog` only after validation. If the project really uses a custom state named `lbacklog`, it should work through configuration rather than hard-coded spelling.

## Scope

- Add a restricted issue-creation capability exposed only to the `nap` profile.
- Validate target project/team scope using the active project configuration.
- Validate target state using Linear diagnostics/workflow state discovery.
- Support a configured backlog state name with a safe default of `Backlog`.
- Define an issue-create payload with:
  - title;
  - problem statement;
  - evidence;
  - why it matters;
  - suggested fix direction;
  - category;
  - source nap run id.
- Create Linear issues through the existing Linear client boundary.
- Return created issue id, identifier, URL, and state.
- Reject malformed, empty, oversized, or unsafe payloads.
- Scrub secrets from payloads before sending to Linear and before persisting events.
- Ensure normal profiles cannot call this tool.

## Out of Scope

- Dashboard queue and runtime task shell. Owned by plan 184.
- Nap profile prompt and no-edit enforcement. Owned by plan 185.
- Deduplication across findings and final summary. Owned by plan 187.
- Raw GraphQL access from Codex.
- Arbitrary issue updates outside the configured project/team.
- Automatically assigning labels beyond a small configured allowlist.

## Acceptance Criteria

- `nap` profile can create a Linear issue through a restricted tool/backend action.
- Refinement, implementation, and merge profiles cannot use the issue-create tool.
- Created issues are placed in the configured backlog state.
- Missing or invalid backlog state returns a clear configuration error before issue creation.
- Payload validation rejects empty title/problem/evidence.
- Payload validation rejects attempts to create issues outside the active project/team.
- Response includes created issue identifier and URL.
- Linear API failures are captured as structured errors without leaking credentials.
- Tests cover allowed profile, forbidden profile, valid create, invalid backlog state, invalid payload, and API failure.

## Test Cases

- Tool specs for `nap` include issue creation.
- Tool specs for implementation do not include issue creation.
- Valid nap create request calls the Linear client with the configured project/team and backlog state.
- Invalid backlog state returns `linear_state_not_found` or an equivalent structured error.
- Empty title returns validation error before Linear API call.
- Oversized body returns validation error before Linear API call.
- Linear API failure returns a sanitized error and records a failed creation event.

## Implementation Notes

- Prefer a new tool name such as `linear_issue_create`.
- Do not add issue creation to `linear_task_update`; that API is intentionally current-task scoped.
- Use existing Linear client normalization patterns for GraphQL responses.
- Keep all issue creation policy in Symphony backend, not in prompt text.
- Consider a maximum issues-per-run guard so a malformed audit cannot create an unbounded number of Linear issues.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/linear/client_test.exs`
- `mise exec -- mix test test/symphony_elixir/linear/diagnostics_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Implemented the restricted `linear_issue_create` tool for both `nap` and `day_dreaming` profiles so the shared issue-only audit/discovery paths can use one backend boundary.

## Dependencies

- [033-linear-task-read-update-tools.md](../completed/033-linear-task-read-update-tools.md)
- [055-linear-workflow-state-preflight-validation.md](../completed/055-linear-workflow-state-preflight-validation.md)
- [153-linear-client-response-normalization-boundary.md](../completed/153-linear-client-response-normalization-boundary.md)
- [185-nap-profile-and-readonly-contract.md](active/185-nap-profile-and-readonly-contract.md)

## Handoff Notes

The main safety rule is that Codex never gets raw Linear credentials or arbitrary Linear write access. It proposes issue payloads; Symphony validates and creates issues.
