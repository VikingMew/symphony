# 115 Test YAML Fixture Builder

Status: Completed

## Goal

Reduce hand-written workflow/profile YAML fixture drift by introducing a shared test fixture builder for workflow package YAML.

## Background

Plan 109 called out repeated YAML fixture generation. Plan 111 confirmed that tests still contain bespoke heredocs and interpolation for workflow/profile package shapes. This makes field additions expensive and easy to miss.

## Scope

- Inventory tests that construct workflow/profile YAML by hand.
- Introduce a small test-only fixture builder, likely under `test/support`, for:
  - workflow package YAML
  - profiles package YAML
  - combined active workflow maps when YAML format is not the test subject
- Replace repeated fixtures where exact YAML formatting is not being tested.
- Keep explicit heredocs where the test specifically verifies parser behavior, indentation, invalid syntax, or import UX.

## Out of Scope

- Changing production import/export format.
- Adding a production YAML encoder solely for tests.
- Rewriting tests that intentionally exercise exact raw YAML text.

## Acceptance Criteria

- Common workflow-schema tests share one fixture construction path.
- Adding a new workflow field requires changing one fixture builder for ordinary valid YAML fixtures.
- Tests that keep raw YAML heredocs document why exact text matters.
- Existing import/export and config tests pass.

## Test Cases

- Fixture builder unit tests if it contains nontrivial logic.
- Existing workflow import/export tests.
- Existing config/schema tests.
- `mix test --cover`

## Implementation Notes

- Prefer simple Elixir data-to-YAML generation already available in the test toolchain.
- If no structured YAML encoder is appropriate, centralize the string rendering in one helper rather than spreading heredocs.
- Avoid making UI tests assert business parser behavior through long raw YAML strings.

## Verification

- Added `SymphonyElixir.TestSupport.WorkflowFixtures` as the shared test-only fixture builder for split workflow/profile YAML.
- Reused the builder from `TestSupport.write_workflow_file!/2`.
- Replaced the settings import test's repeated split workflow/profile heredocs with builder calls.
- Kept raw YAML heredocs that intentionally verify exact import text, invalid syntax, or parser behavior.
- Added focused tests proving generated fixture YAML is parseable and stable for ordinary values.
- `mix format --check-formatted`
- `mix lint`
- `mix test --cover`

## Completion Deviations

- The existing broad `workflow_import_raw/1` heredoc remains because it verifies combined markdown-style import behavior with front matter and prompt body, where exact raw text matters.

## Dependencies

- Plan 109.
- Plan 111.

## Handoff Notes

Start with `test/support/test_support.exs` and `web_fake_persistence_test.exs`; keep invalid YAML cases explicit.
