# 222 Dialyzer Gate Unblock: Root Cause Fixes

## Goal

Make the dialyzer step of the quality gate deterministic: `mix dialyzer --format short` must
complete without crashing. Fix the four root causes that crash the short formatter and
generate the largest warning clusters. The remaining warning debt is owned by follow-up plans
223 (unused functions) and 224 (remaining warnings).

## Status

Completed.

## Background

`make all` runs `mix dialyzer --format short` (Makefile `dialyzer` target). Today that command
crashes:

```text
** (throw) {:error, :unknown_warning, :exact_compare}
```

dialyxir 1.4.7 (the latest release on hex) does not recognize OTP 28's new `:exact_compare`
warning tag; its short formatter throws on it while the default formatter degrades gracefully
("Unknown warning: :exact_compare"). Running with the default format exposes 117 real dialyzer
warnings across 14 files. None are new regressions from plans 215-221, but the specs added in
plan 220 made several latent type problems visible for the first time.

Root causes fixed by this plan:

1. **Wrong `Payload.get_path/3` spec** (lib/symphony_elixir/payload.ex:20):
   `@spec get_path(map(), [[atom() | String.t()]], term()) :: term()` declares the path as a
   list of lists, but the implementation (`List.wrap/1` per element) and every call site pass a
   flat list (`["params", "item"]`). This single wrong spec produces the largest warning
   cluster: most of the 37 `call` and 14 `no_return` warnings (e.g. run_history.ex
   `completed_item_detail/1`, `token_usage_detail/2`, `rate_limit_detail/1` — dialyzer proves
   the calls always fail).
2. **`exact_compare` source** (lib/symphony_elixir/orchestrator/input_blocker.ex:97):
   `detail in [nil, ""]` where `detail` is a binary. OTP 28's dialyzer emits `exact_compare`
   because `binary() =:= nil` can never be true. `MessageHumanizer.humanize_codex_message/1`
   gained a spec in plan 220, which is why the comparison became provably dead.
3. **Unknown type `SymphonyElixir.Orchestrator.State.t/0`** (4 warnings): the nested
   `defmodule State` at lib/symphony_elixir/orchestrator.ex:40 defines no `@type t`, but
   dispatch_policy.ex specs (lines 86, 103, 127, 132) reference `State.t()`.
4. **Unknown function** (lib/symphony_elixir/first_run_defaults.ex:119): one
   `unknown_function` warning — a call to a function dialyzer cannot resolve.

## Scope

Exactly these four fixes (behavior-preserving):

1. Fix `Payload.get_path/3` (and `get_any/3` if it shares the shape) spec to accept the flat
   path list the implementation and callers use. Suggested:
   `@spec get_path(map(), [atom() | String.t() | [atom() | String.t()]], term()) :: term()`.
2. Fix `input_blocker.ex:97`: replace `detail in [nil, ""]` with an explicit
   `is_nil(detail) or detail == ""` (or equivalent) so the `exact_compare` warning disappears.
3. Add `@type t` to `SymphonyElixir.Orchestrator.State` (or replace `State.t()` in
   dispatch_policy.ex specs with a concrete type such as `map()` — pick whichever is accurate).
4. Resolve the `first_run_defaults.ex:119` unknown function.

Fallback if the short formatter still crashes on another unknown tag after these fixes:
switch the Makefile dialyzer target from `--format short` to the default format (which
degrades gracefully) and record the deviation.

After the fixes, re-run `mix dialyzer --format short` and record the remaining warning count
and list as the baseline for plans 223 and 224. Do not attempt to clear warnings beyond the
four root causes in this plan.

## Out of Scope

- The 32 `unused_fun` warnings — owned by plan 223.
- All remaining `call`/`pattern_match`/`call_without_opaque`/`no_return`/`guard_fail`/
  `contract_with_opaque`/`pattern_match_cov` warnings — owned by plan 224.
- The credo `[R]`/`[D]` debt (35 + 2, recorded in plan 221) — separate follow-up.
- Upgrading dialyxir / OTP (1.4.7 is the latest dialyxir; OTP 28 is the project's pinned toolchain).
- Any behavior, API, config, or test changes beyond the four fixes.

## Acceptance Criteria

- `mise exec -- mix dialyzer --format short` completes without crashing (exit 0 or a clean
  warning list; a formatter crash is a failure).
- The four root-cause warnings are gone: no `exact_compare`, no `unknown_type` for
  `State.t`, no `unknown_function` in first_run_defaults, and the `get_path`-driven
  `call`/`no_return` cluster in run_history.ex and friends is visibly reduced.
- `mise exec -- mix specs.check` still passes.
- `mise exec -- mix format --check-formatted` passes.
- `mise exec -- mix test` still passes (664 tests, 0 failures, 2 skipped expected).
- `mise exec -- mix credo --strict` still reports zero `[F]` (35 `[R]` + 2 `[D]` remain,
  pre-existing).

## Test Cases

- `mix dialyzer --format short` before: crash (`:unknown_warning :exact_compare`). After: no
  crash; warning count reduced from 117 to the 223/224 baseline (expected roughly 60-70).
- Full suite regression: `mix test` (664 expected, 0 failures).
- Format check and specs.check pass after edits.
- `credo --strict` [F] count stays at zero (do not regress plan 221's work).

## Implementation Notes

- Re-run `mix dialyzer --format short` after each of the four fixes to confirm the crash is
  gone and measure the count drop.
- The `get_path` spec change may resolve many downstream warnings at once; verify
  `run_history.ex` (25 warnings) drops without touching the plan 221 refactors.
- `get_any/3` (payload.ex:18) is a bare function with `@spec get_any(map(), [atom()], term())`
  — check its shape too; `get_path` delegates to it via `List.wrap/1`, so both specs must be
  consistent with flat-list callers.
- Dialyzer needs the compiled project; run it from `elixir/` via `mise exec -- mix dialyzer`.

## Verification

Executed by Codex CLI (codex-cli 0.147.0, `--sandbox workspace-write`) and independently
re-verified by the reviewer outside the sandbox:

- `mise exec -- mix dialyzer --format short` -> no formatter crash (was
  `{:error, :unknown_warning, :exact_compare}`). 46 warnings remain, exit 2.
  Progress: 117 -> 52 (payload spec) -> 51 (input_blocker) -> 47 (State.t) -> 46 (IEx fix).
- `mise exec -- mix specs.check` -> pass.
- `mise exec -- mix format --check-formatted` -> pass.
- `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped (reviewer rerun; the first
  reviewer run and one Codex sandbox run each hit 1-2 random failures in
  `OrchestratorStatusTest` / `HookRunnerTest` that pass in isolation — pre-existing
  global-state/timing flakes, same pattern recorded in plan 221, not a regression).
- `mise exec -- mix credo --strict` -> zero `[F]`; 35 `[R]` + 2 `[D]` remain (pre-existing).
- `git diff --check` -> pass. Scope: exactly 4 files modified, 5 insertions / 3 deletions.

### Remaining warning baseline for plans 223/224 (46)

```text
lib/symphony_elixir/agent_runner.ex:68:11:pattern_match
lib/symphony_elixir/agent_runner.ex:127:8:unused_fun codex_message_handler/2
lib/symphony_elixir/agent_runner.ex:133:8:unused_fun send_codex_update/3
lib/symphony_elixir/agent_runner.ex:242:13:pattern_match
lib/symphony_elixir/agent_runner.ex:283:8:unused_fun maybe_mark_implementation_started/2
lib/symphony_elixir/agent_runner.ex:293:8:unused_fun transition_implementation_start/3
lib/symphony_elixir/agent_runner.ex:309:8:unused_fun validate_implementation_start_transition/3
lib/symphony_elixir/agent_runner.ex:318:8:unused_fun call_implementation_start_transitioner/3
lib/symphony_elixir/agent_runner.ex:333:8:unused_fun notify_backend_transition/4
lib/symphony_elixir/agent_runner.ex:357:8:unused_fun do_run_codex_turns/8
lib/symphony_elixir/agent_runner.ex:411:16:pattern_match
lib/symphony_elixir/agent_runner.ex:466:11:pattern_match
lib/symphony_elixir/agent_runner.ex:477:8:unused_fun continuation_settings/1
lib/symphony_elixir/agent_runner.ex:490:8:unused_fun build_turn_prompt/4
lib/symphony_elixir/codex/app_server.ex:47:16:pattern_match
lib/symphony_elixir/codex/app_server.ex:66:18:pattern_match
lib/symphony_elixir/codex/app_server.ex:353:8:unused_fun send_initialize/2
lib/symphony_elixir/codex/app_server.ex:385:8:unused_fun do_start_session/4
lib/symphony_elixir/codex/app_server.ex:392:8:unused_fun start_thread/4
lib/symphony_elixir/codex/app_server.ex:452:8:unused_fun await_startup_response/4
lib/symphony_elixir/codex/app_server.ex:456:8:unused_fun with_timeout_startup_response/7
lib/symphony_elixir/codex/app_server.ex:482:8:unused_fun handle_startup_response/7
lib/symphony_elixir/codex/app_server.ex:511:8:unused_fun append_startup_output/2
lib/symphony_elixir/codex/message_humanizer/wrapper_events.ex:159:8:pattern_match
lib/symphony_elixir/codex/message_humanizer/wrapper_events.ex:170:8:pattern_match_cov
lib/symphony_elixir/codex/update.ex:1:pattern_match
lib/symphony_elixir/codex/update.ex:319:8:pattern_match_cov
lib/symphony_elixir/codex/update.ex:336:88:pattern_match
lib/symphony_elixir/orchestrator.ex:661:40:call_without_opaque active_issue_state?/2
lib/symphony_elixir/orchestrator.ex:733:40:call_without_opaque active_issue_state?/2
lib/symphony_elixir/orchestrator.ex:930:66:call_without_opaque should_dispatch_issue?/4
lib/symphony_elixir/orchestrator.ex:939:54:call_without_opaque terminal_issue_state?/2
lib/symphony_elixir/orchestrator.ex:945:52:call_without_opaque active_issue_state?/2
lib/symphony_elixir/orchestrator.ex:977:8:pattern_match_cov
lib/symphony_elixir/orchestrator.ex:990:20:call_without_opaque size/1
lib/symphony_elixir/orchestrator.ex:1006:12:call_without_opaque revalidate_issue_for_dispatch/3
lib/symphony_elixir/orchestrator.ex:1296:52:call_without_opaque retry_candidate_issue?/2
lib/symphony_elixir/orchestrator.ex:1344:53:call_without_opaque retry_candidate_issue?/2
lib/symphony_elixir/orchestrator.ex:1921:8:pattern_match
lib/symphony_elixir/orchestrator.ex:2321:60:call_without_opaque dispatch_slots_available?/3
lib/symphony_elixir/orchestrator.ex:2410:7:pattern_match_cov
lib/symphony_elixir/orchestrator/dispatch_policy.ex:225:contract_with_opaque normalized_state_set/1
lib/symphony_elixir/orchestrator/input_blocker.ex:69:7:pattern_match
lib/symphony_elixir/run_history.ex:370:8:pattern_match_cov
lib/symphony_elixir_web/admin/project_settings.ex:171:guard_fail
lib/symphony_elixir_web/proxy_headers.ex:64:5:call_without_opaque to_string/1
```

Category counts at baseline: 17 `unused_fun` (plan 223 — all in `agent_runner.ex` and
`codex/app_server.ex`), 11 `pattern_match`, 5 `pattern_match_cov`, 11 `call_without_opaque`,
1 `contract_with_opaque`, 1 `guard_fail` (plan 224). Note: the original 117-warning breakdown
(from the default formatter) reported 32 `unused_fun`; the short-format baseline after plan 222
is 17, which is the authoritative count the gate uses.

## Completion Deviations

- All four root causes fixed as planned; the Makefile fallback was not needed (the short
  formatter no longer crashes once the `exact_compare` warning is gone).
- `IEx.started?/0` (first_run_defaults.ex:119) could not be resolved by dialyzer because IEx
  is not part of the PLT. Replaced with the behaviorally equivalent
  `is_nil(Process.whereis(IEx.Config))` (checks whether the IEx config process is running).
  This is the only non-spec, non-type edit in the plan.
- The `input_blocker.ex` fix drops the `nil` arm of `detail in [nil, ""]` because
  `humanize_codex_message/1`'s spec proves `detail` is a non-nil binary; behavior is
  unchanged for all values the spec allows.

## Dependencies

- Plan 221 (credo `[F]` cleanup) is complete. Plans 223 (unused functions) and 224 (remaining
  warnings) continue the dialyzer cleanup after this plan.

## Handoff Notes

Codex delegation candidate following the plan 221 pattern. Run Codex in the repository working
tree (uncommitted 215-221 changes present — do not revert or commit them). Note:
`--sandbox workspace-write` blocks network and `~/.hex` writes, so run `mix dialyzer` directly
rather than `make all` (setup would fail inside the sandbox). Require the
Completed/Validation/Deviations/Blockers report format, including the exact remaining warning
count and list for the 223/224 handoff. Reviewer (Hermes) must re-run the dialyzer + test
gates independently before moving this plan to `completed/`.
