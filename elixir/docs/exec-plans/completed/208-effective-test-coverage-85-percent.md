# 208 Effective Test Coverage 85 Percent

## Goal

Raise Symphony's effective Elixir test coverage to at least 85% while shrinking coverage-ignore debt instead of hiding untested behavior behind broad ignored modules.

## Status

Completed.

## Background

`mix.exs` already configures:

- `test_coverage.summary.threshold: 85`;
- a large `coverage_ignore_modules()` list split into protocol/process boundary, storage boundary, and presentation shell groups.

That threshold is useful, but it is not enough by itself. A project can pass an 85% coverage gate while still ignoring important runtime modules. The real target should be:

- measured counted coverage is at least 85%;
- ignored modules have explicit exit slices;
- high-value pure boundaries are counted and tested;
- broad process, storage, and LiveView shells remain ignored only where per-line coverage is still misleading.

## Scope

- Establish a current coverage baseline with the existing ignore list.
- Record coverage by module where possible, especially for low-coverage counted modules.
- Review `coverage_ignore_groups/0` in `mix.exs` and choose a first wave of modules to exit the ignore list.
- Prefer modules that already have extracted pure boundaries or focused tests:
  - schema changesets;
  - response normalization;
  - presenter/payload helpers;
  - controller response helpers;
  - extracted orchestrator/workspace policies.
- Add focused tests for uncovered branches until total counted coverage remains at or above 85% after the first ignore-list reduction.
- Keep permanent framework shells ignored only when they are genuinely generated or side-effect shells.
- Add documentation or checker output that makes the current ignore list and exit reasons visible during coverage work.

## Out of Scope

- Chasing 100% coverage.
- Counting process shells before their side-effect boundaries are extracted.
- Writing brittle tests against Phoenix-generated internals.
- Replacing meaningful integration tests with shallow line-hit tests.
- Removing every coverage ignore entry in one pass.

## Acceptance Criteria

- `mix test --cover` reports at least 85% coverage.
- At least one non-trivial module or coherent module group exits `coverage_ignore_modules/0`.
- Any module removed from the ignore list has focused tests that cover its public contract and important failure branches.
- The coverage threshold remains configured at 85 or higher.
- The remaining ignore groups still include specific `remove_when` / `exit_slices` reasons.
- No new module is added to the ignore list without an explicit exit condition.
- CI or the local lint/test workflow fails when coverage drops below 85%.

## Suggested First Wave

- Storage schemas whose behavior can be covered with changeset tests:
  - `SymphonyElixir.Persistence.RunRecord`;
  - `SymphonyElixir.Persistence.TaskRecord`;
  - `SymphonyElixir.Persistence.Worker`;
  - `SymphonyElixir.Persistence.WorkspaceRecord`.
- Presentation helpers that can be covered without LiveView process coupling:
  - `SymphonyElixirWeb.ErrorHTML`;
  - `SymphonyElixirWeb.ErrorJSON`;
  - `SymphonyElixirWeb.StaticAssetController`;
  - `SymphonyElixirWeb.ObservabilityApiController`.
- Extracted policy/helper modules created by completed plans 192-207, if they are counted and not already covered.

## Test Cases

- Coverage baseline test run:
  - run the full suite with coverage;
  - record total coverage and ignored module count.
- Schema coverage tests:
  - valid changeset accepts required fields;
  - missing required fields are rejected;
  - enum/status fields reject invalid values;
  - optional fields preserve nil/default behavior.
- Controller/rendering coverage tests:
  - success response shape;
  - not-found/error response shape;
  - cache/header behavior where applicable.
- Governance test:
  - coverage ignore list still exposes category, exit slice, and remove condition for every ignored module.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test --cover`
  - Result: 620 tests, 0 failures, 2 skipped.
  - Coverage: 85.89%, above the 85% threshold.
- Focused coverage exits:
  - `test/symphony_elixir/persistence/schema_changeset_test.exs`
  - `test/symphony_elixir/codex/token_usage_test.exs`
  - `test/symphony_elixir/workflow_validator_test.exs`
  - `test/symphony_elixir/codex/message_humanizer_methods_test.exs`
  - `test/symphony_elixir/codex/message_humanizer_wrapper_events_test.exs`
  - `test/symphony_elixir/orchestrator/session_history_test.exs`
  - `test/symphony_elixir_web/proxy_headers_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

The first-wave schema modules exited the ignore list and are covered by changeset tests. Three large shells were kept under governed coverage-ignore debt with explicit exit slices instead of being forced through brittle tests: `Persistence.WorkerQueue`, `Persistence.WorkflowStore`, and `WorkersLive`. This matches the current no-real-database-test direction and keeps their future exits documented in `coverage_ignore_groups/0`.

## Dependencies

- Completed plan 106 for coverage ignore list governance.
- Completed plan 114 for coverage ignore exit governance.
- Completed plan 123 for coverage ignore exit slices.
- Completed plan 172 for coverage ignore exit after extractions.
- Completed plans 192-207 for recent boundary and test splits that should make more modules countable.

## Handoff Notes

Do not game the number. If a module is still ignored, keep the reason specific and temporary unless it is a genuine framework shell. The target is 85% coverage with better signal, not 85% produced by a larger blind spot.
