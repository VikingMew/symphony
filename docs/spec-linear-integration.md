---
title: Issue Tracker Integration Specification
genre: spec
domain: [spec, linear-integration]
status: current
language: en
owner: SymphonyElixir.Linear
updated: 2026-08-27
---

# Issue Tracker Integration Specification

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.

A non-Linear implementation MAY change transport details, but the normalized outputs MUST match the
domain model in [spec-domain-model §4](spec-domain-model.md).

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in [spec-domain-model §4.1](spec-domain-model.md).

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes and Implementation Handoff

- Codex requests task-scoped mutations through the restricted `linear_task_update` tool; raw Linear
  GraphQL is not exposed to the agent.
- The default implementation completion target is exactly `Ready to Merge` and requires a final
  comment, structured result, and references.
- `AgentRunner` MUST ensure the exact GitHub repository/base/head PR is open before the tool attaches
  references, posts the comment, or moves Linear. The Linear state update is last.
- PR failure leaves the issue in `In Progress`. Linear write failure after PR creation is typed and
  visible so a retry can reuse the already-open PR.
- `Ready to Merge` is a waiting state. Symphony performs no `Ready to Merge -> Done` write; Linear's
  GitHub merged-PR automation owns successful completion.
- Human change requests move `Ready to Merge -> In Progress`; Codex updates the same branch/PR and
  explicitly requests `Ready to Merge` again after validation.
