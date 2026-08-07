# 065 Linear Reference Attachment Linking

## Goal

Bind concrete implementation references to the current Linear issue when Codex
reports them through the restricted `linear_task_update` tool.

## Status

Completed.

## Background

Symphony already reads Linear `branchName` and lets Codex include `branch`,
`commit`, `pr_url`, and `references` in comments/results. That leaves the issue
association mostly textual. Linear supports issue attachments that link external
URLs to an issue. We can use that from the backend without exposing raw GraphQL
or the Linear API key to Codex.

The desired scope is deliberately small: bind an issue to concrete URLs that
Codex already knows, not implement a full branch lifecycle, PR creation, or git
provider integration.

## Scope

- Extend `linear_task_update` so URL references can be linked to the current
  Linear issue using Linear attachments.
- Keep the existing comment/result behavior.
- Accept concrete URL fields from `references` and `result`, including PR,
  commit, branch, and generic URL entries.
- Return attachment-link results in the restricted tool response.
- Keep non-URL values such as branch names, commit SHAs, and comment ids as
  comment/result context only.
- Add focused tests for extraction, no-op behavior, and attachment mutation
  payloads.

## Out of Scope

- Creating git branches.
- Generating commit URLs from provider-specific repository remotes.
- Pushing code or creating pull requests.
- Exposing raw Linear GraphQL to Codex.
- Replacing existing comments/results with attachments.

## Acceptance Criteria

- `linear_task_update` links supported URL references to the current issue.
- Link creation is scoped to the current issue id from the session context.
- `references` that contain only non-URL metadata do not call Linear attachment
  mutations.
- A failed attachment mutation fails the restricted update response with a clear
  error.
- The tool response includes attachment results when reference links are
  attempted.
- Tests cover PR/commit/branch URL inputs and non-URL metadata.
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs` passes.
- `mise exec -- mix lint` passes.

## Test Cases

- `linear_task_update` with `references.pr_url` creates one attachment link.
- `linear_task_update` with `result.commit_url` creates one attachment link.
- `linear_task_update` with `references.urls` creates one attachment per HTTP
  URL.
- `linear_task_update` with only `latest_human_comment_id` creates no
  attachment link and still succeeds.
- Attachment mutation failure returns a failed tool response.

## Implementation Notes

- Use Linear `attachmentCreate` from the backend client boundary.
- Keep the dynamic tool count unchanged by reusing `linear_task_update`.
- Deduplicate URLs before creating attachments.
- Generate conservative titles from the field name, for example `Pull Request`,
  `Commit`, `Branch`, or `Reference`.
- Only accept `http://` and `https://` URLs for attachment linking.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix test`
- `mise exec -- mix test --cover` (`83.40%` total)

## Completion Deviations

- Existing `linear_task_update` behavior already appends `references` to a
  comment. That behavior remains unchanged, so non-URL reference metadata still
  creates or contributes to the comment body while skipping attachment linking.

## Dependencies

- Existing restricted Linear task update tool.
- Existing Linear GraphQL client.

## Handoff Notes

None yet.
