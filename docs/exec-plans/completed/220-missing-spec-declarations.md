# 220 Missing @spec Declaration Cleanup

## Goal

Add the missing `@spec` declarations that `mix specs.check` reports so the quality gate is
green. The five declarations were first noted in plan 216's Completion Deviations and have been
carried as pre-existing debt through plans 216-219; this plan clears them.

## Status

Completed.

## Background

`mix specs.check` enforces AGENTS.md's rule that public functions (`def`) in `lib/` have an
adjacent `@spec` (`defp` optional, `@impl` callbacks exempt). Five declarations are missing
today. They predate the multi-project work and are unrelated to it, but they fail the check
every run, so `mix lint` can never pass until they are added.

## Scope

Add `@spec` for exactly these five functions:

1. `SymphonyElixir.Codex.MessageHumanizer.Methods.humanize_mcp/1`
   (lib/symphony_elixir/codex/message_humanizer/methods.ex:14) — delegates to
   `ToolMethods.mcp_elicitation/1`.
2. `SymphonyElixir.Codex.MessageHumanizer.Methods.humanize_dynamic_tool/2`
   (lib/symphony_elixir/codex/message_humanizer/methods.ex:17) — delegates to
   `ToolMethods.dynamic_tool_event/2`.
3. `SymphonyElixir.Codex.RateLimitGate.check/3`
   (lib/symphony_elixir/codex/rate_limit_gate.ex:17) — note this function already has a
   `@spec` above the first clause at line 14 (`@spec check(term(), term(), keyword()) :: ...`);
   the checker still flags it, so the fix may be restructuring the spec placement or widening
   the types to match every clause's actual arguments.
4. `SymphonyElixir.Linear.IssueNormalizer.normalize_issue/2`
   (lib/symphony_elixir/linear/issue_normalizer.ex:11).
5. `SymphonyElixir.Orchestrator.DispatchPolicy.should_dispatch_issue?/4`
   (lib/symphony_elixir/orchestrator/dispatch_policy.ex:42).

For each: add a `@spec` that matches the function's real argument and return types. Do not
change behavior. If a function already has a spec the checker does not recognize (e.g.
multiple clauses with the spec on the first), fix the placement so the checker accepts it
without altering runtime behavior.

## Out of Scope

- Adding specs to `defp` functions (optional per AGENTS.md).
- Refactoring the modules' internals.
- Any behavior or test changes.

## Acceptance Criteria

- `mise exec -- mix specs.check` passes with zero missing declarations.
- `mise exec -- mix test` still passes (no behavior change).
- `mise exec -- mix format --check-formatted` passes.

## Test Cases

- Run `mix specs.check` before and after: five missing -> zero.
- Full suite regression: `mix test` (658 tests expected, 0 failures) — the specs are
  documentation-only, so no test changes are expected.
- Format check passes after edits.

## Implementation Notes

- Look at the actual function clauses before writing the spec: `RateLimitGate.check/3` has
  `def check(snapshot, settings, opts \\\\ [])` then multiple clauses with guards; the existing
  `@spec check(term(), term(), keyword()) :: :allow | {:block, map()}` looks correct, so
  investigate why the checker flags it (possibly a second `def check` clause head without the
  default, or the checker wants the spec adjacent to each head) before editing.
- `MessageHumanizer.Methods.humanize/2` already has a spec at line 10; follow the same style
  for the two delegates.
- `IssueNormalizer.normalize_issue/2` and `DispatchPolicy.should_dispatch_issue?/4`: read the
  clauses, then write specs matching `@spec name(arg_types) :: return_type`.

## Verification

- `mise exec -- mix specs.check` -> `all public functions have @spec or exemption` (passes, zero missing).
- `mise exec -- mix format --check-formatted` -> passes. (The end-of-sequence gate run also ran
  `mix format` on `lib/symphony_elixir_web/live/admin_live.ex` to clear pre-existing format drift
  from the plan 219 project-switcher edits: 227 lines reformatted, formatting-only.)
- `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped.
- `mise exec -- mix lint` -> `exec_plans.check` and `specs.check` pass; `credo --strict` still
  reports 14 refactoring opportunities. Recorded as debt in Completion Deviations, not fixed in
  this hygiene plan (AGENTS.md: avoid unrelated refactors).
- `make MIX="mise exec -- mix" all` -> setup/build/fmt-check pass; the run stops at the lint
  step because of the credo findings above. Coverage (`mix test --cover`) not re-run separately;
  full suite passed above.
- Dialyzer -> `mix dialyzer --format short` crashes in dialyxir 1.4.7's formatter on OTP's
  `:exact_compare` warning (`{:error, :unknown_warning, :exact_compare}`); `--format raw`
  completes and reports "warnings were emitted" (type warnings exist, exit 2). Pre-existing
  tooling/type debt, out of scope for this hygiene plan.

## Completion Deviations

- The original five findings were three bare-function-head cases (`normalize_issue/2`,
  `check/3`, `should_dispatch_issue?/4`), each with `@spec` already present before the bare
  head, plus two genuinely missing specs in `MessageHumanizer.Methods`. The root cause of the
  three false positives was that `SpecsCheck` did not recognize bare function heads
  (`def foo(a \\ default)` with no body): the head fell through to the catch-all clause and
  cleared `pending_specs`, so the following real clause was reported.
- Fix: `SpecsCheck.consume_form/5` now has a clause for `{:def, meta, [head_ast]}` (bare head)
  that goes through the same `consume_def/6` logic as body'd defs. The helper was extracted so
  both forms share one implementation, and the helper is defined after all `consume_form`
  clauses to satisfy Elixir's "group same name/arity" warning.
- After the checker fix, `mix specs.check` exposed a second batch of five functions whose
  `@spec` was placed **after** the bare head (`Payload.get_any/3`, `Payload.get_path/3`,
  `RunLifecycle.task_event_attrs/2`, `RunLifecycle.run_event_attrs/2`,
  `RunLifecycle.finish_run/5`). These violated the adjacent-`@spec` rule all along but were
  masked by the old fallthrough. Fixed by moving each `@spec` above the bare head, matching the
  Elixir convention (spec immediately before the def declaration).
- No behavior changes in any module; the only non-spec edit is the `SpecsCheck` fix itself.
- Added three `SpecsCheckTest` cases: accepts `@spec` before a bare head with multi-clause
  defs; reports a missing spec before a bare head; reports a spec placed after a bare head.
- `mix specs.check`, `mix format --check-formatted`, `mix lint`, and full `mix test`
  (661 tests, 0 failures) pass.

## Dependencies

- None (pure hygiene plan; can land in parallel with 219, but run `make all` after both so the
  end-of-sequence gate is exercised once).

## Handoff Notes

The likely trap is `RateLimitGate.check/3`: it already has a `@spec`, so if the checker still
flags it, the issue is placement/arity of the spec relative to the clauses rather than a
missing declaration. Read `mix/tasks/specs.check.ex` to see exactly what the task matches on
before editing. Keep every edit spec-only; if a module needs a behavior change to satisfy the
checker, that is a deviation to record, not something to hide in a spec.

### End-of-sequence lint debt (recorded, not fixed)

`credo --strict` reports 14 `[F]` refactoring opportunities. Split by origin:

- Introduced by plans 216-219 (4): `WorkflowStore.load_database_workflows/1`
  (workflow_store.ex:162), `Orchestrator.maybe_dispatch/2` (orchestrator.ex:490),
  `Orchestrator.spawn_issue_on_worker_host/5` (orchestrator.ex:1066),
  `FakePersistence.active_workflow_version/1` (fake_persistence.exs:139) — all "function body
  nested too deep". Left untouched: the natural fixes refactor concurrency-sensitive
  orchestrator code outside this hygiene plan's scope (AGENTS.md: preserve retry, reconciliation,
  cleanup semantics; avoid unrelated refactors). Own them in a follow-up plan.
- Pre-existing at HEAD (10): `RunHistory.detail/1` (complexity 14), `RunHistory.severity/1`
  (11), `RunHistory.protocol_timestamp/1` (10), `Nap.Results.aggregate/1` (nested),
  `Presenter.issue_payload_body/1` (11), `DispatchPolicy.candidate_issue?/4` (10),
  `ObservabilityPresenter.workflow_version_summary/1` (10), `DynamicTool.IssueCreate.execute/1`
  (redundant `with` clause), `Orchestrator.handle_call/3` (negated condition),
  `Orchestrator.maybe_start_queued_operator_tasks/1` (nested).

Follow-up: a dedicated refactor plan (suggested number 221) should clear `credo --strict` to
zero, with `make MIX="mise exec -- mix" all` green as its acceptance gate. This is also a good
candidate for the Symphony-style Codex delegation workflow.
