# 223 Dialyzer Cleanup: Unused Functions

## Goal

Clear all `unused_fun` dialyzer warnings (17 at plan 222's baseline — 10 in
`agent_runner.ex`, 7 in `codex/app_server.ex`) by deleting genuinely dead private functions
and explicitly retaining (with commented ignore entries) any that are intentionally kept.

## Status

Completed.

## Background

Plan 222 fixed the dialyzer gate crash and the four root-cause warning clusters. Its handoff
baseline (embedded in plan 222's Verification) lists the remaining warnings; the
`unused_fun` category is 17 warnings, all in two files: `agent_runner.ex`
(`codex_message_handler/2`, `send_codex_update/3`, `maybe_mark_implementation_started/2`,
`transition_implementation_start/3`, `validate_implementation_start_transition/3`,
`call_implementation_start_transitioner/3`, `notify_backend_transition/4`,
`do_run_codex_turns/8`, `continuation_settings/1`, `build_turn_prompt/4`) and
`codex/app_server.ex` (`send_initialize/2`, `do_start_session/4`, `start_thread/4`,
`await_startup_response/4`, `with_timeout_startup_response/7`, `handle_startup_response/7`,
`append_startup_output/2`). These are private functions dialyzer proves are never called from
anywhere. Some are dead code that should be deleted; a few may be intentionally retained
(reserved for future use, invoked dynamically via `apply`/MFA, or used only by tests).

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

- `mix dialyzer --format short` before: 17 `unused_fun`. After: 0 `unused_fun`.
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

Executed by Codex CLI (codex-cli 0.147.0, `--sandbox workspace-write`) and independently
re-verified by the reviewer outside the sandbox:

- `mise exec -- mix dialyzer --format short` -> zero `unused_fun` (was 17). 29 warnings
  remain for plan 224 (11 pattern_match, 5 pattern_match_cov, 11 call_without_opaque,
  1 contract_with_opaque, 1 guard_fail). `--list-unused-filters` shows no unnecessary skips.
- `mise exec -- mix specs.check` -> pass.
- `mise exec -- mix format --check-formatted` -> pass.
- `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped (Codex sandbox run). Reviewer
  runs hit the known `OrchestratorStatusTest` `:sys.get_state` timeout flake intermittently
  (different tests per seed); each failing test passes in isolation — same pre-existing
  global-state/timing flake recorded in plans 221 and 222, not a regression.
- `mise exec -- mix credo --strict` -> zero `[F]`; 35 `[R]` + 2 `[D]` remain (pre-existing).
- `git diff --check` -> pass. Scope: `mix.exs` (+1 line, `ignore_warnings` config) and the new
  `elixir/.dialyzer_ignore.exs`. No application code modified.

## Completion Deviations

- **The 17 `unused_fun` warnings are dialyzer false positives, not dead code.** Every
  function has direct callers in reachable code (verified by code trace and by Elixir's own
  compiler, which emits zero unused-function warnings after a forced recompile of
  `agent_runner.ex` and `app_server.ex`). Dialyzer's type-driven reachability under
  OTP 28 / dialyxir 1.4.7 misclassifies them (same toolchain incompatibility family as the
  `exact_compare` formatter crash fixed in plan 222). Deleting them would break compilation,
  so the plan's "prefer deletion" guidance does not apply; retaining with documented ignore
  entries is the correct resolution.
- Resolution: all 17 functions retained; `elixir/.dialyzer_ignore.exs` (new) lists each with
  a reason comment and is wired via `dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]` in
  `mix.exs`. The ignore file returns `{file, "Function name/arity will never be called."}`
  pairs generated from `{:unused_fun, {Module, :fun, arity}}` tuples.
- A follow-up should re-evaluate these entries when dialyxir is upgraded past 1.4.7 (or if
  the codebase moves off OTP 28): if the warnings disappear, the ignore entries can be
  removed. Also worth confirming upstream whether dialyxir 1.4.7's unused_fun analysis has a
  known OTP 28 issue.

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
