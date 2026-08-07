# 196 Test Support Dynamic Atom Fixture Boundary

## Goal

Remove unbounded atom creation from `test/support/fake_persistence.exs` while preserving the test helper's ability to normalize known run/event fixture fields.

## Status

Completed.

## Background

`test/support/fake_persistence.exs` currently converts arbitrary binary keys with `String.to_atom/1`. This is outside production code, but it still hides bad fixture shape and trains tests to accept payloads the runtime should not accept.

Test support should be stricter than production where possible. It should normalize only known fields and fail loudly when a fixture introduces an unexpected atom-key requirement.

## Scope

- Replace binary-key `String.to_atom/1` conversion in fake persistence with a closed key map.
- Keep supported fixture keys explicit and easy to extend.
- Decide whether unknown string keys should remain strings or fail test setup; prefer failing when the helper is normalizing persisted domain fields.
- Add focused tests for known string-key normalization and unknown-key behavior.
- Keep test helper behavior aligned with real persistence schema rather than widening compatibility.

## Out of Scope

- Rewriting fake persistence from scratch.
- Changing production persistence schema.
- Fixing unrelated fake persistence line-count or ownership issues.

## Acceptance Criteria

- `rg "String\\.to_atom" test/support/fake_persistence.exs` returns no matches.
- Known fixture payloads used by existing tests still work.
- Unknown fixture keys do not become atoms.
- The helper documents the closed key set in code through data structure shape, not prose comments.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/dynamic_atom_usage_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir_web/live/settings_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 121 for dynamic atom conversion cleanup.
- Completed plan 170 for fake persistence test split.
- Completed plan 180 for settings/observability fake persistence test split.

## Handoff Notes

This is not a production security fix, but it protects the test suite from normalizing bad data too generously. Keep the key boundary small and schema-shaped.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

