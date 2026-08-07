# 187 Nap Audit Results And Dedup

## Goal

Record nap audit output, deduplicate discovered problems within a run, and show a useful final summary to the operator.

This plan connects the nap task to auditable results after the Dashboard queue, profile, and issue-create tool exist.

## Status

Completed.

## Background

The nap task can produce many findings. Without result tracking and deduplication, it can spam Linear with duplicate issues or leave the operator unable to tell what happened.

The operator needs a clear answer after a run:

- how many findings were created as Linear issues;
- how many were skipped as duplicates;
- how many failed validation or Linear creation;
- links to the created issues.

## Scope

- Add a nap audit result model or event shape tied to a nap run id.
- Track per-finding status:
  - created;
  - skipped duplicate;
  - validation failed;
  - create failed.
- Deduplicate findings within a single nap run before creating Linear issues.
- Define a stable fingerprint from normalized title/category/evidence target.
- Persist created Linear issue identifiers and URLs.
- Persist sanitized failure reasons.
- Show final summary on Dashboard and/or run detail.
- Include source nap run id in created issue body.
- Add event history entries for issue creation, duplicate skip, and failures.

## Out of Scope

- Cross-run global duplicate detection against all historical Linear issues.
- Full similarity search or embeddings.
- Dashboard queue/start behavior. Owned by plan 184.
- Profile prompt/no-edit behavior. Owned by plan 185.
- Linear issue creation tool. Owned by plan 186.
- Automatically closing or merging duplicate Linear issues.

## Acceptance Criteria

- Each nap run records created/skipped/failed counts.
- Duplicate findings within the same run do not create duplicate Linear issues.
- Created issue links are visible to the operator.
- Failed findings preserve a sanitized reason.
- Dashboard or run detail shows the latest nap summary.
- Events page/run history has readable nap events.
- Tests cover dedup fingerprinting, result counting, persisted links, and failure summaries.

## Test Cases

- Two identical findings in one run produce one created issue and one skipped duplicate.
- Two different findings with different evidence targets create two issues.
- A validation failure increments failed count and does not call Linear.
- A Linear API failure increments failed count and records sanitized reason.
- Final summary renders created/skipped/failed counts and created issue URLs.

## Implementation Notes

- Keep dedup deterministic and simple for the first slice.
- A candidate fingerprint can normalize:
  - title;
  - category;
  - primary file path;
  - primary symbol or line reference if present.
- Do not hide skipped duplicates; operators need to know when Codex found repeated instances.
- Reuse existing persisted event/session-history presentation patterns where possible.
- If a dedicated table is too much for the first slice, a structured event payload is acceptable only if the Dashboard/run detail can query it reliably.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/nap_test.exs`
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Implemented deterministic in-run aggregation/dedup and Dashboard summary rendering. Results are currently represented as structured runtime summary data rather than a dedicated persistence table.

## Dependencies

- [184-dashboard-nap-control-and-queue.md](active/184-dashboard-nap-control-and-queue.md)
- [185-nap-profile-and-readonly-contract.md](active/185-nap-profile-and-readonly-contract.md)
- [186-nap-linear-issue-create-tool.md](active/186-nap-linear-issue-create-tool.md)
- [141-run-detail-agent-execution-summary.md](../completed/141-run-detail-agent-execution-summary.md)
- [158-runtime-results-analytics-page.md](../completed/158-runtime-results-analytics-page.md)

## Handoff Notes

Keep the first dedup rule boring and explainable. This feature is meant to create useful backlog work, not to become a fuzzy issue triage system in the first implementation.
