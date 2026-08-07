# 197 Documentation Alignment Plan Lifecycle Drift

## Goal

Correct the documentation-alignment matrix so it no longer points at completed plans as active work, and add a checkable lifecycle rule for future drift.

## Status

Completed.

## Background

`docs/documentation_alignment.md` still says boundary/test refactors are owned by `active 176-182`, but plans 176-182 are now completed. Current completed plan work is 192-194 plus any new completed plans added after this audit.

This is a code/documentation consistency issue: the project guidance sends readers to the wrong lifecycle bucket.

## Scope

- Update the affected alignment row to distinguish completed 176-182 from currently active follow-up work.
- Ensure references to active execplan numbers match files under `docs/exec-plans/active/`.
- Prefer wording that names active scope categories instead of stale fixed ranges when work is ongoing.
- Add a lightweight check or documented review step if the existing execplan checker cannot validate this drift.

## Out of Scope

- Rewriting the entire documentation alignment matrix.
- Moving completed plans.
- Changing completed plan contents.

## Acceptance Criteria

- `docs/documentation_alignment.md` no longer says `active 176-182`.
- Every fixed active-number reference in the file maps to an existing completed plan file.
- Completed plan ranges are described as completed, not active.
- `mix exec_plans.check` still passes after the update.

## Verification

- `rg -n "active 176-182|176-182" elixir/docs/documentation_alignment.md`
- `ls elixir/docs/exec-plans/active`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plans 176-182.
- Completed plans 192-194.

## Handoff Notes

This plan exists because the current instruction is to create plans only. The eventual implementation should touch documentation, but only when the user allows existing docs to be edited.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

