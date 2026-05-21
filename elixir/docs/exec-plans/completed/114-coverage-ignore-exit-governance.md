# 114 Coverage Ignore Exit Governance

Status: Completed

## Goal

Convert the coverage ignore list from a broad waiver into a governed list with categories, removal conditions, and tests that prevent new unowned ignores.

## Background

Plan 106 raised coverage to the project threshold and added rationale comments. Plan 111 found remaining residual debt: broad runtime, storage, and presentation modules are still ignored, and the comments do not yet give per-entry removal conditions.

## Scope

- Categorize each ignored module as one of:
  - protocol/process boundary
  - storage boundary
  - presentation shell
  - missing-test debt
- Add an explicit removal condition or owner note for each ignored module or grouped module family.
- Add a test or check that fails if new ignored modules are added without a reason and removal condition.
- Identify the first ignored pure/helper module that can be removed from the ignore list, if any.

## Out of Scope

- Raising the global coverage threshold beyond 85%.
- Forcing every ignored module to become covered in this plan.
- Rewriting presentation or process modules solely to satisfy line coverage.

## Acceptance Criteria

- Every ignored module entry or grouped family has a documented category and removal condition.
- A test or lint check fails for unannotated additions to the ignore list.
- Newly extracted pure helper modules are not ignored by default.
- `mix test --cover` remains at or above threshold.

## Test Cases

- Coverage governance unit/check test for ignore-list annotations.
- `mix test --cover`
- `mix lint`

## Implementation Notes

- Keep annotations close to `mix.exs` or move the data into a small structured module if that makes it testable.
- Avoid adding process-heavy modules back into coverage until meaningful focused tests exist.

## Verification

- Replaced the inline broad `ignore_modules` list with governed `coverage_ignore_groups/0`.
- Categorized ignored modules into protocol/process boundary, storage boundary, and presentation shell groups.
- Added removal conditions for each group.
- Added tests that fail if the configured ignore list diverges from the governed groups or if newly extracted helper modules are ignored by default.
- `mix format --check-formatted`
- `mix lint`
- `mix test --cover`

## Completion Deviations

- No modules were removed from the ignore list in this slice. The plan focused on making ignores owned and testable before shrinking them.

## Dependencies

- Plan 106.
- Plan 111.

## Handoff Notes

This plan is about governance first. Removing ignored modules is useful only when tests describe behavior rather than inflating line coverage mechanically.
