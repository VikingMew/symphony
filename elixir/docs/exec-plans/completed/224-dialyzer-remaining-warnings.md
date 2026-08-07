# 224 Dialyzer Cleanup: Remaining Warnings

## Goal

Clear every remaining dialyzer warning after plans 222 and 223 so
`mise exec -- mix dialyzer --format short` exits 0 with **zero warnings**, making the dialyzer
step of `make all` fully green.

## Status

Completed.

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

Executed by Codex CLI (codex-cli 0.147.0, `--sandbox workspace-write`) and independently
re-verified by the reviewer outside the sandbox:

- `mise exec -- mix dialyzer --format short` -> **exit 0, ZERO warnings**
  (`done (passed successfully)`). The dialyzer gate is fully green for the first time
  (was 117 warnings at plan 222's start).
- `mise exec -- mix specs.check` -> pass.
- `mise exec -- mix format --check-formatted` -> pass.
- `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped (reviewer run; Codex sandbox
  run also passed after the known OrchestratorStatusTest flake passed in isolation).
- `mise exec -- mix credo --strict` -> zero `[F]`; 35 `[R]` + 2 `[D]` remain (pre-existing).
- `git diff --check` -> pass. Scope: exactly the 10 whitelisted files, +91/-61 lines.
  `elixir/.dialyzer_ignore.exs` untouched (plan 223 entries intact).

Fixes by category:
- `pattern_match` / `pattern_match_cov` / `guard_fail`: removed unreachable clauses
  (input_blocker.ex generic blocked clause, wrapper_events.ex `humanize_item_type` fallbacks,
  update.ex `history_detail` fallback, run_history.ex `bounded_payload` fallback,
  project_settings.ex `safe_path_segment` guard + caller fallback, orchestrator.ex
  `dispatch_policy_settings(_state)` fallback) and aligned expressions with established
  runtime types (update.ex `compute_token_delta` integer-only paths, run_history.ex
  `event_payload` map guard).
- `call_without_opaque` / `contract_with_opaque`: new opaque constructor
  `DispatchPolicy.build_settings/1` + `@opaque dispatch_settings` with `@typep settings_source`
  (orchestrator.ex `dispatch_policy_settings` now builds through it); `proxy_headers.ex`
  constructs external URLs via `URI.new!/1` + `URI.append_path/2` with an `external_origin/3`
  helper (also brackets IPv6 hosts, a small correctness improvement); app_server.ex
  `session_policies/2` re-expressed via `Config.settings()` +
  `Schema.resolve_runtime_turn_sandbox_policy/3`.

## Completion Deviations

- None blocking. Observations recorded for follow-up:
  - `app_server.ex` now inlines the same logic as `Config.codex_runtime_settings/2`
    (resolve_session_policies is line-for-line equivalent; verified against config.ex:181).
    The duplication could be collapsed back to a `Config.codex_runtime_settings` call if that
    function's spec is added — but the local form is what satisfies dialyzer under the
    whitelist, so it stays as-is.
  - `proxy_headers.ex` now brackets IPv6 hosts in generated external URLs (was previously
    un-bracketed) — a deliberate correctness improvement surfaced by the opaque-type fix.
  - `run_history.ex` `event_payload` now returns `%{}` for non-map payloads (previously
    passed through truthy non-map values); callers treat the result as a map, so this is a
    strictness improvement, not a regression.
  - All removed clauses were dialyzer-proven unreachable; the full suite (664 tests) covers
    the affected modules and passes.

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
