# 256 Retire backend merge and trim the default workflow

## Goal

Remove Symphony's backend feature-merge/default-branch-push path and make `Ready to Merge` the
single human waiting state between implementation and GitHub/Linear-owned completion.

## Status

Active.

## Background

The former defaults routed review/merge states to a backend merge executor. That mixed human review,
agent work, and default-branch delivery, and allowed Symphony to update the base branch. PR-first
delivery needs the smaller flow `Refining -> Needs Refinement Review -> Ready -> In Progress ->
Ready to Merge -> Done`.

## Scope

- Delete the merge executor, its AgentRunner route, merge helper, and default-branch push path.
- Remove the default merge profile and merge success-state setting.
- Default active states to `Refining`, `Ready`, and `In Progress`.
- Default human-review states to `Needs Refinement Review` and `Ready to Merge`.
- Route only refinement and implementation states; protect `Ready to Merge` from dispatch.
- Keep `Ready to Merge -> In Progress` for human change requests.
- Make `Done` the sole successful terminal state while preserving cancellation terminals.
- Align schema defaults, package examples, Settings/FakePersistence fixtures, diagnostics/bootstrap,
  prompts, specs, designs, and operator docs.

## Out of Scope

- Programmatic Linear state archival or team automation configuration.
- Automatic migration of live issues in retired states.
- Editing completed exec plans that historically describe the old merge path.

## Acceptance Criteria

- No runtime code merges a feature branch or pushes `HEAD` to the default branch.
- `Ready to Merge` is inactive, unrouteable, and never moved to `Done` by Symphony.
- Current defaults/docs contain no retired delivery route; rollout mentions old state names only for
  manual cleanup/archive.
- Checked-in YAML is clearly an import/export example; every enabled project requires a new active
  SQLite workflow version.
- Operator checklist covers automation race avoidance, service/SSH auth, DB cutover, live-issue
  handling, and later state archival.

## Test Cases

- Default schema/profile/transition assertions and dispatch exclusion.
- Settings, diagnostics, discovery, bootstrap, and workflow validator fixtures.
- Repository search excluding completed historical plans.
- Full format/lint/coverage/dialyzer gate.

## Implementation Notes

Generic state-name normalization remains generic. State-specific policy belongs in defaults,
workflow/profile configuration, prompts, diagnostics, tests, and current documentation.

## Verification

- Focused config/workflow/diagnostics/settings suites: passed.
- `mix specs.check`, `mix docs.check`, `mix exec_plans.check`: passed.
- `make all`: passed with 748 tests, 0 failures, 2 skipped, and 85.31% coverage.

## Completion Deviations

None at implementation time.

## Dependencies

- Active plan 255 owns atomic PR sequencing.
- Per-team Linear merged-to-`Done` automation is an operator prerequisite.

## Handoff Notes

Archive retired Linear states only after manual live-issue cleanup. Ensure PR-open automation cannot
overwrite Symphony's `Ready to Merge` handoff.
