# 231 Wire Nap operator results into summaries (or delete)

## Goal

Make operator-task completion summaries reflect real created issues; wire Nap.Results into the actual flow or remove it.

## Status

Completed.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Dead code [1] (high): nap/results.ex, orchestrator.ex:1919-1920.

`Nap.Results.aggregate/2` is only called from tests. Real issue creation flows through `DynamicTool.IssueCreate` and its audit (`linear_tool_audit`), but operator completion summaries hard-code `%{created: 0, skipped: 0, failed: 0}` even when issues were actually created. The summary is actively misleading.

## Scope

- Decide: wire `linear_issue_create` audit results into the operator task summary (preferred — the audit trail exists), or delete `Nap.Results` and its misleading counter fields.
- If wiring: operator run state carries created/skipped/failed counts from the audit events; summary reflects them.
- Update `orchestrator.ex` `operator_task_summary/2` accordingly.

## Out of Scope

- New operator UI; changing audit event format.

## Acceptance Criteria

- Operator task that created N issues reports `created: N` in its summary (integration-level test).
- `Nap.Results` either has real consumers or is deleted with its tests.
- Orchestrator summary contract (issue/run history) unchanged for non-operator runs.

## Test Cases

- Integration: run an operator task with a stub audit (2 created, 1 skipped) => summary reflects it.
- If deletion chosen: remove module + tests, verify no references.

## Implementation Notes

Prefer wiring over deletion if the audit data is trustworthy; if the count semantics are unreliable, delete rather than display fiction (Linus: show the code, not the claim).

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 32 [R] + 2 [D], down from 35 [R] baseline)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 677 tests, 0 failures, 2 skipped (full suite; first two runs hit known
  flaky OrchestratorStatusTest timeout, third run fully green; flaky files run in isolation: 41 tests, 0 failures)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (results.ex, orchestrator.ex, nap_test.exs, orchestrator_operator_tasks_test.exs)

## Completion Deviations

- Chose wiring over deletion: audit trail (`linear.tool_call` events with tool `linear_issue_create`)
  is trustworthy; `operator_task_summary/2` became `/3` and queries events by run_id via
  `Persistence.list_events/1` (supports run_id/event_type/order/limit), then aggregates with `Nap.Results`.
- `Nap.Results.aggregate/1` is a new contract: it aggregates issue-creation audit events
  (status success/skipped/failure) instead of the old `aggregate/2` finding-dedup + create-callback
  shape. The old fingerprint/validation semantics had no production consumer and were replaced, not deleted.
- Failed operator tasks now keep `failed: max(count, 1)` plus the `error` field, and still reflect any
  created/skipped issues from the run's audit trail (previously hard-coded `%{created: 0, ...}` on failure).
- Summary `issues` entries are the audit event result maps (e.g. `%{"identifier" => "CCR-10"}`),
  not finding payloads; non-operator run summaries are untouched.
- `operator_task_results/1` caps the query at 10 000 events ascending; a non-binary run_id yields an
  empty summary.

## Dependencies

None.

## Handoff Notes

Executed by Codex CLI in a clean worktree (`--sandbox workspace-write`). Prompt must
carry: file whitelist, environment-noise rules (Mix.PubSub/port/socket errors in sandbox
are noise — continue), forbid touching docs/exec-plans and design docs, forbid adding
`.dialyzer_ignore.exs` entries, forbid custom build environments (`_build/codex_*`),
report format (Completed / Validation / Deviations / Blockers). Reviewer runs the full
gate sequence outside the sandbox, reviews the diff for behavior equivalence, archives
this plan, and commits.
