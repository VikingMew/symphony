# 195 Nap Results Dynamic Atom Removal

## Goal

Remove the production `String.to_atom/1` call from `SymphonyElixir.Nap.Results` and make nap-result parsing use a closed, explicit key boundary.

## Status

Completed.

## Background

`lib/symphony_elixir/nap/results.ex` currently normalizes string keys by calling `String.to_atom(key)` inside `get_string/2`. This reintroduces the same unbounded atom-creation risk that completed plan 121 was meant to remove from production code.

The dynamic-atom governance test scans production files for this pattern, but the call site exists today. That means the intended invariant and the implementation have drifted.

## Scope

- Replace `String.to_atom/1` in `Nap.Results` with explicit mixed-key access.
- Limit accepted atom keys to a closed vocabulary used by nap result payloads.
- Prefer `SymphonyElixir.Payload.get_any/3` or a local closed-key helper over ad hoc conversion.
- Add or update focused tests that prove string-key and atom-key fixture payloads still parse correctly.
- Ensure the production dynamic-atom scan rejects future reintroductions.

## Out of Scope

- Changing nap prompt content.
- Changing the result schema beyond key-access normalization.
- Reworking `linear_issue_create` or operator-run persistence.

## Acceptance Criteria

- `rg "String\\.to_atom" lib/symphony_elixir/nap/results.ex` returns no matches.
- Nap result parsing still accepts existing string-key payloads.
- Nap result parsing still accepts known atom-key payloads without creating atoms dynamically.
- Unknown string keys are ignored or treated as absent; they are never converted to atoms.
- The dynamic atom governance test passes and would catch this class of regression.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/dynamic_atom_usage_test.exs`
- `mise exec -- mix test test/symphony_elixir/nap_results_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 121 for dynamic atom conversion cleanup.
- Completed plan 187 for nap result summary semantics.

## Handoff Notes

Do not solve this by rescuing `String.to_existing_atom/1`. The right boundary is an explicit key list or the shared payload accessor so external payload shape cannot allocate VM atoms.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

