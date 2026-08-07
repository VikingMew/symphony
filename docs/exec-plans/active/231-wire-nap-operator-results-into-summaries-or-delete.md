# 231 Wire Nap operator results into summaries (or delete)

## Goal

Make operator-task completion summaries reflect real created issues; wire Nap.Results into the actual flow or remove it.

## Status

Active.

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

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (664 baseline, 0 failures, 2 skipped; known flaky:
  OrchestratorStatusTest `:sys.get_state` timeout, HookRunnerTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

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
