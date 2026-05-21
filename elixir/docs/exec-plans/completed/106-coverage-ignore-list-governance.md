# 106 Coverage Ignore List Governance

## Goal

Make the test coverage threshold meaningful by reducing and justifying the broad `ignore_modules` list in `mix.exs`.

## Status

Completed.

## Background

`mix.exs` sets a coverage threshold of 85, but the coverage configuration excludes many core modules, including orchestration, agent execution, Codex app-server integration, dynamic tools, workspace management, persistence, LiveViews/controllers, and Mix tasks.

That means coverage can pass while high-risk runtime behavior is outside the metric. Some ignores may be justified because they wrap external systems or are already covered through integration paths, but the current list does not document those reasons and is too broad to guide quality decisions.

## Scope

- Classify every ignored module by reason.
- Remove ignores for modules that are deterministic enough to count toward coverage.
- Add focused tests for extracted or pure boundaries.
- Document any remaining ignores with rationale.
- Keep the threshold realistic while improving signal.

Suggested categories:

- External process/protocol boundary.
- UI rendering boundary.
- Persistence/storage boundary.
- Pure logic that should not be ignored.
- Legacy broad module pending extraction.

## Out of Scope

- Chasing 100% coverage.
- Requiring live Linear, live Codex, Docker, SSH, or GitHub in coverage tests.
- Replacing ExUnit coverage tooling.
- Performing all large-module extractions in this plan.

## Acceptance Criteria

- `mix.exs` has a smaller or explicitly justified coverage ignore list.
- Pure modules and deterministic extracted boundaries count toward coverage.
- Coverage output better reflects risk in the runtime control plane.
- The coverage threshold remains achievable with local deterministic tests.
- Any remaining ignored module has a reason that future maintainers can evaluate.

## Test Cases

- Run `mise exec -- mix test --cover` and confirm the threshold still passes.
- Add direct tests for at least one currently ignored pure or mostly pure boundary, such as dynamic-tool payload normalization or presentation helpers, if not already counted.
- Add a regression test around any module removed from the ignore list before removing it.
- Ensure integration-style tests are not used as the only proof for pure extracted helpers.

## Implementation Notes

- Start with an audit table in a short doc or code comment near the coverage config if that is the least noisy place.
- Prefer removing ignores after plan 105 extracts smaller boundaries from large modules.
- Candidates likely worth counting first:
  - `SymphonyElixir.Codex.DynamicTool`
  - pure config/schema helpers that are currently reachable through broader tests
  - extracted admin form/import helpers
  - extracted workspace source-strategy helpers
  - extracted orchestrator policy helpers
- Candidates that may remain ignored temporarily:
  - direct process launch wrappers
  - Phoenix endpoint/router modules
  - modules that require significant external-service fakes before coverage would mean anything
- Avoid weakening the threshold to make this pass. If the threshold must change, explain why and set a follow-up target.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test --cover`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

The coverage ignore list now has rationale comments and no longer ignores the deterministic `SymphonyElixirWeb.Presenter` path. New run-history, run-lifecycle, shell, redaction, state-name, and payload modules are counted through direct tests. `SymphonyElixir.Codex.DynamicTool` and `SymphonyElixir.StatusDashboard` remain ignored as broader protocol/presentation boundaries until they are split further; removing them in this pass made coverage fail without improving signal.

## Dependencies

- Plan 104 for the original audit finding.
- Plan 105 for extracting smaller units that can be counted meaningfully.
- Existing coverage configuration in `mix.exs`.

## Handoff Notes

This should be treated as quality-governance work, not cosmetic cleanup. The desired outcome is a coverage metric that helps identify risk, especially around workflow parsing, dynamic tools, workspace preparation, and orchestration policy.
