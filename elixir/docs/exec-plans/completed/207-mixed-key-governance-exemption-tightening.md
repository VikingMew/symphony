# 207 Mixed Key Governance Exemption Tightening

## Goal

Tighten the manual mixed-key access governance allowlist so broad file-level exemptions do not become permanent compatibility debt.

## Status

Completed.

## Background

Completed plan 181 added governance for manual mixed atom/string key access. The current allowlist still includes broad production files such as analytics, dashboard presenters, `AdminLive`, message humanizer methods, worker queue, and nap results.

Some mixed-key access is legitimate at external payload boundaries. The debt is that broad file-level exemptions make it easy to add new ad hoc access without choosing a boundary or explaining why the payload is mixed.

## Scope

- Review every file-level exemption in the mixed-key governance test.
- Replace broad exemptions with narrower module/function/pattern allowances where practical.
- Move repeated mixed-key access behind shared helpers or closed local accessors.
- Require a short owner/reason for any remaining exemption.
- Remove exemptions made obsolete by completed plans 195 and 196.

## Out of Scope

- Eliminating every mixed-key access in one pass.
- Changing external payload schemas.
- Reworking all presenters.
- Duplicating the dynamic atom scan.

## Acceptance Criteria

- The governance allowlist is smaller or more precise than the current broad file list.
- New manual mixed-key access in an exempted file is harder to add silently.
- Remaining exemptions identify the external boundary they protect.
- Production dynamic atom usage remains forbidden.
- Tests document the acceptable compatibility surface.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/mixed_key_access_governance_test.exs`
- `mise exec -- mix test test/symphony_elixir/dynamic_atom_usage_test.exs`
- `rg -n "Map\\.get\\([^\\n]+:" lib/symphony_elixir test/support`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 121 for dynamic atom conversion cleanup.
- Completed plan 181 for manual mixed-key access governance.
- Completed plan 195 for nap result dynamic atom removal.
- Completed plan 196 for test support dynamic atom fixture boundary.

## Handoff Notes

Keep legitimate payload-boundary compatibility, but make it explicit. A broad allowlist is a promise to forget the debt.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

