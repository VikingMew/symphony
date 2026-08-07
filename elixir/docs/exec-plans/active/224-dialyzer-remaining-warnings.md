# 224 Dialyzer Cleanup: Remaining Warnings

## Goal

Clear every remaining dialyzer warning after plans 222 and 223 so
`mise exec -- mix dialyzer --format short` exits 0 with **zero warnings**, making the dialyzer
step of `make all` fully green.

## Status

Active.

## Background

Plans 222 (root causes) and 223 (unused functions) cleared the dialyzer crash and the
`unused_fun` category. What remains is the mixed tail of warnings — at plan 222's baseline
these were approximately 45 warnings across:

- 37 `call` (minus those resolved by the `get_path` spec fix in 222)
- 14 `no_return` (minus those resolved by the `get_path` spec fix)
- 11 `pattern_match` + 4 `pattern_match_cov`
- 11 `call_without_opaque` + 1 `contract_with_opaque`
- 1 `guard_fail`

Concentrated in `codex/message_humanizer/methods.ex` (~18), `codex/update.ex` (~15),
`agent_runner.ex` (~14), `codex/message_humanizer/wrapper_events.ex` (~9),
`codex/app_server.ex` (~9), `dispatch_policy.ex` (~5), `input_blocker.ex` (~2), and a few
singletons (`proxy_headers.ex`, `project_settings.ex`, etc.).

## Scope

Drive the remaining warning count to zero:

1. Re-run `mix dialyzer --format short` to get the authoritative post-222/223 warning list.
2. Work warning by warning, category by category:
   - `call` / `no_return`: verify the failing call first (wrong spec vs genuinely wrong code).
     Fix the spec to match the real values; fix the code only when the code is wrong (e.g. a
     path that can never return).
   - `pattern_match` / `pattern_match_cov`: usually an impossible pattern (value known to be
     narrower than the pattern); fix the pattern or the upstream type.
   - `call_without_opaque` / `contract_with_opaque`: opaque type violations (e.g.
     `proxy_headers.ex:64` builds a `%URI{}` that does not satisfy `URI.t()`); fix the
     construction or the spec.
   - `guard_fail`: a guard that can never succeed for the argument type.
3. Prefer fixing specs over widening types carelessly; never mute a warning to hide a real
   bug.

## Out of Scope

- `unused_fun` warnings — plan 223 (should already be zero).
- The credo `[R]`/`[D]` debt — separate follow-up.
- Upgrading dialyxir / OTP.
- Any behavior, API, or test changes beyond what a warning fix requires.

## Acceptance Criteria

- `mise exec -- mix dialyzer --format short` exits 0 with **zero warnings** and no formatter
  crash.
- `mise exec -- mix specs.check` still passes.
- `mise exec -- mix format --check-formatted` passes.
- `mise exec -- mix test` still passes (664 tests, 0 failures, 2 skipped expected).
- `mise exec -- mix credo --strict` still reports zero `[F]`.
- `make MIX="mise exec -- mix" all` reaches and passes the dialyzer step when run directly
  (the lint step's pre-existing credo exit-6 remains the only documented gate blocker).

## Test Cases

- `mix dialyzer --format short` before: N remaining warnings (post-222/223 baseline). After:
  exit 0, zero warnings.
- Full suite regression: `mix test` (664 expected, 0 failures).
- Format check and specs.check pass after edits.
- `credo --strict` [F] count stays at zero.

## Implementation Notes

- Work category by category and re-run `mix dialyzer --format short` after each batch; the
  count is the progress metric.
- `methods.ex` and `update.ex` warnings are mostly `call` warnings against
  `String.t()`-returning helpers — verify actual return values (they may return nil) before
  widening specs; the correct fix may be `String.t() | nil` or handling nil at call sites.
- For `no_return`: a true no-return function is a real bug; fix it or record a deviation with
  a follow-up link — do not hide it in an ignore file.
- `run_history.ex` warnings should already be largely resolved by 222's `get_path` fix; do
  not re-refactor the plan 221 helpers.
- If a warning cannot be fixed without a behavior change, record it in Completion Deviations
  with a follow-up plan link instead of muting it.

## Verification

- `mise exec -- mix dialyzer --format short` (zero warnings, exit 0)
- `mise exec -- mix specs.check`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test`
- `mise exec -- mix credo --strict` (0 `[F]`)
- `make MIX="mise exec -- mix" all` (record where it stops; expected: lint exit-6 only)

## Completion Deviations

None yet.

## Dependencies

- Plans 222 (gate unblock) and 223 (unused functions) must be complete first. After this
  plan, the only remaining `make all` gate blocker is the credo `[R]`/`[D]` debt from plan 221.

## Handoff Notes

Codex delegation candidate. Run in the repository working tree (uncommitted 215-223 changes
present — do not revert or commit them). Sandbox note: `--sandbox workspace-write` blocks
network and `~/.hex` writes, so run `mix dialyzer` directly, not `make all`. This is the
largest of the three dialyzer plans by judgment required (spec correctness vs code
correctness); if the session runs long, prefer finishing category by category with a clear
partial report over a rushed zero-warning claim. Require the Completed/Validation/Deviations/
Blockers report format. Reviewer (Hermes) must re-run the full dialyzer + test gates
independently before moving this plan to `completed/`.
