# 221 Credo --strict Lint Debt Cleanup

## Goal

Clear all 14 `credo --strict` `[F]` refactoring opportunities recorded in plan 220's Completion
Deviations so the `make all` quality gate stops at lint for debt reasons only (ideally passes
the lint step entirely).

## Status

Completed.

## Background

`mix lint` is `exec_plans.check` + `specs.check` + `credo --strict`. The first two pass; the
last one currently reports 14 failing `[F]` checks:

- 4 were introduced by plans 216-219 (the multi-project work): all "function body is nested too
  deep".
- 10 predate the sequence (present at HEAD before 215): mostly "function is too complex"
  (cyclomatic complexity over the max of 9), plus two nesting issues, one redundant `with`
  clause, and one negated condition.

None of these are correctness bugs; they are refactoring opportunities. The fix for each is a
behavior-preserving refactor (extract private helpers, invert conditions, drop redundant
clauses).

## Scope

Refactor exactly the 14 functions below so `credo --strict` reports zero `[F]` issues. For
each, keep the public signature and observable behavior identical; internal restructuring only.

Introduced by 216-219 (4):

1. `SymphonyElixir.WorkflowStore.load_database_workflows/1` — lib/symphony_elixir/workflow_store.ex:162 (nested too deep, depth 3).
2. `SymphonyElixir.Orchestrator.maybe_dispatch/2` — lib/symphony_elixir/orchestrator.ex:490 (nested too deep, depth 3).
3. `SymphonyElixir.Orchestrator.spawn_issue_on_worker_host/5` — lib/symphony_elixir/orchestrator.ex:1066 (nested too deep, depth 4).
4. `SymphonyElixir.TestSupport.FakePersistence.active_workflow_version/1` — test/support/fake_persistence.exs:139 (nested too deep, depth 3).

Pre-existing at HEAD (10):

5. `SymphonyElixir.RunHistory.detail/1` — lib/symphony_elixir/run_history.ex:129 (complexity 14, max 9).
6. `SymphonyElixir.RunHistory.severity/1` — lib/symphony_elixir/run_history.ex:330 (complexity 11).
7. `SymphonyElixir.RunHistory.protocol_timestamp/1` — lib/symphony_elixir/run_history.ex:437 (complexity 10).
8. `SymphonyElixir.Nap.Results.aggregate/1` — lib/symphony_elixir/nap/results.ex:40 (nested too deep, depth 3).
9. `SymphonyElixirWeb.Presenter.issue_payload_body/1` — lib/symphony_elixir_web/presenter.ex:72 (complexity 11).
10. `SymphonyElixir.Orchestrator.DispatchPolicy.candidate_issue?/4` — lib/symphony_elixir/orchestrator/dispatch_policy.ex:139 (complexity 10).
11. `SymphonyElixirWeb.Admin.ObservabilityPresenter.workflow_version_summary/1` — lib/symphony_elixir_web/admin/observability_presenter.ex:25 (complexity 10).
12. `SymphonyElixir.Codex.DynamicTool.IssueCreate.execute/1` — lib/symphony_elixir/codex/dynamic_tool/issue_create.ex:54 (redundant last `with` clause).
13. `SymphonyElixir.Orchestrator.handle_call/3` — lib/symphony_elixir/orchestrator.ex:1569 (negated condition in if-else).
14. `SymphonyElixir.Orchestrator.maybe_start_queued_operator_tasks/1` — lib/symphony_elixir/orchestrator.ex:1704 (nested too deep, depth 3).

## Out of Scope

- The 35 `[R]` readability issues (`Line is too long`, alias ordering, etc.) — they do not fail
  `credo --strict`'s failing priority and would bloat the diff.
- Adding `@spec` to `defp` functions.
- Any behavior, API, config, or test changes.
- Refactoring any function not listed above, even if it appears related.

## Acceptance Criteria

- `mise exec -- mix credo --strict` exits 0 with zero `[F]` issues (readability `[R]` may remain).
- `mise exec -- mix specs.check` still passes (all public functions have @spec or exemption).
- `mise exec -- mix format --check-formatted` passes.
- `mise exec -- mix test` still passes (664 tests, 0 failures, 2 skipped expected).
- `make MIX="mise exec -- mix" all` proceeds past lint (format, lint) and the remaining
  coverage/dialyzer steps behave as they did before this plan (dialyzer currently has an
  unrelated formatter crash on OTP's `:exact_compare` warning — record, do not fix here).

## Test Cases

- Run `mix credo --strict` before and after: 14 `[F]` -> 0.
- Full suite regression: `mix test` (664 tests expected, 0 failures) — refactors are
  behavior-preserving, so no test changes are expected; if a refactor forces a test change,
  that is a deviation to record, not a silent edit.
- Format check passes after edits.

## Implementation Notes

- Read each function's full body before extracting. Prefer extracting the deepest nested branch
  into a `defp` helper (or a small set of helpers) named after the branch's purpose. Keep
  helper placement next to the caller in the same module.
- Complexity fixes: split distinct branches (e.g. per-status/per-format handling) into private
  helpers and delegate from the public function. Do not loosen guards or change control flow
  semantics (retry, reconciliation, cleanup ordering in the Orchestrator must be preserved).
- `Orchestrator` is stateful and concurrency-sensitive: keep `handle_call` clauses
  recognizable, preserve the exact call/return contract, and prefer the smallest edit that
  satisfies the check (e.g. invert a negated `if` condition rather than restructuring the
  clause).
- `Nap.Results.aggregate/1` and `RunHistory.*` are pure data functions — extraction is low
  risk; prefer extracting per-case helpers.
- `IssueCreate.execute/1`: remove the redundant last `with` clause (the `else` that only
  re-raises) only if it is truly redundant; otherwise restructure minimally.
- After each module edit, run the targeted test file(s) for that module, then the full suite.
- Do not touch the exec plan files or design docs.

## Verification

Executed by Codex CLI (codex-cli 0.147.0, `--sandbox workspace-write`) and independently
re-verified by the reviewer:

- `mise exec -- mix credo --strict` -> zero `[F]` (was 14). 35 `[R]` readability + 2 `[D]`
  design suggestions remain (pre-existing, out of scope); Credo 1.7.16's category exit masks
  (readability=4, design=2) make the literal exit code 6 even with zero `[F]`.
- `mise exec -- mix specs.check` -> pass.
- `mise exec -- mix format --check-formatted` -> pass.
- `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped (full suite).
- `git diff --check` on all scoped files -> pass.
- `make MIX="mise exec -- mix" all` -> not runnable from inside the Codex sandbox (setup
  needs network + `~/.hex` writes, denied by `--sandbox workspace-write`). Reviewer ran the
  gate steps directly; `make all`'s lint step still exits non-zero because `mix lint` =
  `credo --strict` inherits the same exit-6 behavior from the out-of-scope `[R]`/`[D]`.

## Completion Deviations

- All 14 scoped functions were refactored as planned; every refactor was behavior-preserving
  and confined to the nine scoped files. No tests, exec plans, or design docs were modified.
- Deviating from the literal "credo --strict exits 0" wording: the command now reports zero
  `[F]` but still exits 6 because Credo 1.7.16's strict-mode exit masks count the 35
  pre-existing `[R]` and 2 `[D]` findings that plan 221 explicitly scoped out. Closing the
  remaining gap so `mix lint`/`make all` pass requires either clearing all 37 `[R]`/`[D]`
  items (a larger, mostly mechanical debt) or adjusting the lint policy (e.g. non-strict
  credo, which fails only on `[F]`). Both options are follow-up decisions, not part of this
  plan's 14-function scope.
- One combined targeted-test run in the Codex session hit a global-state timeout; the file
  passed 41/41 in isolation, a focused rerun passed 44/44, and the full suite passed
  (664/0/2), so this is a test-isolation flake, not a regression.

## Dependencies

- Plan 220 (spec hygiene) is complete; 221 lands after it so the end-of-sequence gate is
  exercised with both in place.

## Handoff Notes

This plan is the first candidate for the Symphony-style Codex delegation workflow: the plan
defines the exact function list, the acceptance gate is mechanical (`credo --strict` -> 0,
tests green), and the changes are behavior-preserving refactors. Run Codex in the repository
working tree (current state includes uncommitted 215-220 changes — do not revert or commit
them). Give Codex the plan path and the acceptance commands; require the
Completed/Validation/Deviations/Blockers report format. Reviewer (Hermes) must diff-review the
changes, run the full gate, and then move this plan to `completed/`.
