# 223 Dialyzer Cleanup: Unused Functions

## Goal

Clear all `unused_fun` dialyzer warnings (32 at plan 222's baseline) by deleting genuinely
dead private functions and explicitly retaining (with commented ignore entries) any that are
intentionally kept.

## Status

Active.

## Background

Plan 222 fixed the dialyzer gate crash and the four root-cause warning clusters. Its handoff
baseline lists the remaining warnings; the largest single category is `unused_fun` (~32
warnings): private functions in `lib/` that dialyzer proves are never called from anywhere.
Some are dead code that should be deleted; a few may be intentionally retained (reserved for
future use, invoked dynamically via `apply`/MFA, or used only by tests).

## Scope

For every `unused_fun` warning in the plan 222 baseline:

1. Confirm the function has no callers anywhere in `lib/`, `test/`, or via dynamic
   invocation (`apply/3`, MFA tuples, `Module.concat`-style dispatch). Search
   `&Module.fun/arity` captures, `fun(&1)`, and string-built MFA calls before classifying.
2. If genuinely dead: delete the function (and any now-unused helper specs/docs it drags in).
3. If intentionally retained: keep it, and add a commented entry to `.dialyzer_ignore.exs`
   (new file wired via `dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]` in mix.exs) in
   dialyxir's `{:unused_fun, {Module, :fun, arity}}` term format, with a `# why` comment.

After the cleanup, re-run `mix dialyzer --format short` and confirm zero `unused_fun`
warnings remain; hand the remaining warning list to plan 224.

## Out of Scope

- Non-`unused_fun` warnings (call/pattern_match/no_return/opaque/etc.) — plan 224.
- The credo `[R]`/`[D]` debt — separate follow-up.
- Refactoring the bodies of retained functions.
- Any behavior, API, or test changes.

## Acceptance Criteria

- `mise exec -- mix dialyzer --format short` reports **zero `unused_fun` warnings** (other
  warning categories may remain for plan 224).
- No deleted function is referenced anywhere (compile + full test suite prove it).
- `.dialyzer_ignore.exs` (if created) has only commented, intentional entries.
- `mise exec -- mix specs.check` still passes.
- `mise exec -- mix format --check-formatted` passes.
- `mise exec -- mix test` still passes (664 tests, 0 failures, 2 skipped expected).
- `mise exec -- mix credo --strict` still reports zero `[F]`.

## Test Cases

- `mix dialyzer --format short` before: ~32 `unused_fun`. After: 0 `unused_fun`.
- Full suite regression: `mix test` (664 expected, 0 failures) — deleting a function that a
  test uses would fail the suite, so the suite is the safety net.
- `mix credo --strict` [F] count stays at zero.
- `mix format --check-formatted` passes (deletions must not leave dangling blank lines).

## Implementation Notes

- The exact warning list is in the plan 222 handoff baseline; re-run `mix dialyzer` to get
  the authoritative list if the baseline file is not available.
- Use `grep -rn "function_name"` across the repo before deleting; check for `apply`-style
  dynamic calls and test references.
- Prefer deletion for anything not referenced; the project favors small diffs and no dead
  code. Only retain when there is a concrete reason (documented in the ignore comment).
- Do not touch function bodies; if a retained function has warnings in other categories,
  those belong to plan 224.

## Verification

- `mise exec -- mix dialyzer --format short` (zero `unused_fun`; record remaining list)
- `mise exec -- mix specs.check`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test`
- `mise exec -- mix credo --strict` (0 `[F]`)

## Completion Deviations

None yet.

## Dependencies

- Plan 222 (dialyzer gate unblock) must be complete first so the short formatter does not
  crash. Plan 224 (remaining warnings) continues after this plan.

## Handoff Notes

Codex delegation candidate. Run in the repository working tree (uncommitted 215-222 changes
present — do not revert or commit them). Sandbox note: `--sandbox workspace-write` blocks
network and `~/.hex` writes, so run `mix dialyzer` directly, not `make all`. The `.dialyzer_ignore.exs`
format for dialyxir 1.4.7 is a list of Elixir terms; verify the exact tuple shape by running
`mix dialyzer --format short` and reading how retained warnings print, or check dialyxir docs
for `{:unused_fun, {Module, :fun, arity}}`. Require the Completed/Validation/Deviations/
Blockers report format. Reviewer (Hermes) must re-run gates independently before moving this
plan to `completed/`.
