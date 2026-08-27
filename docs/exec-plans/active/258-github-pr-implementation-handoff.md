# 258 GitHub PR implementation handoff

## Goal

Make centralized implementation completion an explicit, backend-owned, atomic handoff: Codex
pushes the exact Linear branch and requests `Ready to Merge`; Symphony ensures the exact open
GitHub PR before it performs final Linear writes.

## Status

Active.

## Background

A clean app-server exit and max-turn exhaustion only mean a turn stopped. They do not prove that
implementation, validation, commit, or push finished. Initial PR creation also needs one owner and
must support SSH-host execution where the worker workspace is absent on the Symphony host.

## Scope

- Add an injectable GitHub PR boundary using runtime `gh` first and Req/GitHub REST fallback when
  `GH_TOKEN` or `GITHUB_TOKEN` is available.
- Validate issue metadata, Linear branch, default branch, GitHub repository identity, and remote
  branch before lookup/create.
- Reuse an exact existing open PR; reject a closed/merged branch PR as a typed conflict.
- Require final comment/result/references on explicit `Ready to Merge` requests.
- Order PR preparation before attachment/comment and put the Linear state update last.
- Emit started/completed/failed handoff phase events with issue/session/run context and PR URL.
- Keep the boundary independent from a local workspace path.

## Out of Scope

- Approving or merging PRs.
- Installing/configuring Linear GitHub integration in application code.
- Non-GitHub forges or an external HTTP worker executor.

## Acceptance Criteria

- Exact repository/base/head PR exists before `In Progress -> Ready to Merge`.
- Existing open PR is idempotent and produces no create call.
- PR title includes the issue identifier and body includes exact `Fixes <ID>`.
- Missing branch/auth, repository mismatch, closed/merged PR, CLI/API failure, and Linear failure are
  typed and visible; PR failure performs no Linear completion writes.
- Normal turn exit/max turns are inert.
- Local and SSH-host tests do not depend on a Symphony-local workspace.

## Test Cases

- `gh` lookup reuse, create, create-race reread, conflict, repository mismatch, missing branch/auth.
- REST lookup/create fallback and proxy-compatible request boundary.
- Token/output redaction.
- Dynamic tool ordering and AgentRunner end-to-end phase context.

## Implementation Notes

The PR boundary lives under `SymphonyElixir.GitHub.PullRequest`; `AgentRunner` injects it into the
restricted dynamic tool. The tool prepares the PR, attaches references, creates the final comment,
and updates state last. The interface consumes repository metadata and remote state only.

## Verification

- Focused handoff, GitHub, AgentRunner, and policy suites: passed.
- `mix specs.check`, `mix docs.check`, `mix exec_plans.check`: passed.
- `make all`: passed with 748 tests, 0 failures, 2 skipped, and 85.31% coverage.

## Completion Deviations

None at implementation time.

## Dependencies

- Active plan 256 for trimmed default states and removal of backend merge ownership.
- Runtime GitHub auth through authenticated `gh` or environment token.

## Handoff Notes

Operational rollout must follow the ordered checklist in `docs/user-guide.zh-CN.md`; changing the
checked-in package examples alone does not change active SQLite workflow versions.
