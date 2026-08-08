# 238 Fix workspace disk guard fail-open

## Goal

Stop the workspace disk-safety gate from passing when its own evaluation fails.

## Status

Completed.

## Background

Source: REFACTOR_REVIEW.md H2 (Codex static analysis, 2026-08-08). `WorkspaceDiskGuard.check/2`
already models `df` failure and parse failure as `{:error, reason}` (workspace_disk_guard.ex:10-23,
37-65), but `ensure_workspace_disk_available/1` in the orchestrator (orchestrator.ex:1268-1281,
callers at 1123, 1222) wraps the whole evaluation in a catch-all `rescue` that logs a warning and
returns `:ok`. Any unexpected exception (config access, guard bug) therefore BYPASSES the disk gate:
both issue agents and operator tasks keep starting. AGENTS.md's "Explicit errors over silent
tolerance" forbids a safety gate that treats evaluation failure as passing; Carmack's "minimize the
number of things that can go wrong" forbids catch-all rescues that hide program errors.

## Scope

- `lib/symphony_elixir/orchestrator.ex` (`ensure_workspace_disk_available/1` and both call sites):
  normalize ANY exception into `{:error, %{reason: :disk_guard_evaluation_failed, ...}}` with
  structured logging — never return `:ok` from the rescue.
- Route the error through the existing blocked/failed path already used by a normal guard denial
  (issue agents and operator tasks must both fail visibly, not silently pass).
- `lib/symphony_elixir/workspace_disk_guard.ex` unchanged unless a narrow improvement is proven
  needed; the bug is in the caller's rescue, not in `check/2`.

## Out of Scope

- Redesigning disk-gate policy, thresholds, or roots.
- Touching the rate-limit gate (K7 keep-as-is applies).

## Acceptance Criteria

- A stubbed `WorkspaceDiskGuard` that raises produces a blocked/error result for BOTH an issue
  agent dispatch and an operator task start — no `:ok` pass-through.
- A normal denial (`{:error, free_bytes: ...}`) still blocks exactly as today.
- A normal allow (`{:ok, ...}`) still proceeds.

## Test Cases

- Orchestrator test: `WorkspaceDiskGuard.check/2` raises -> run-start attempt records
  blocked/error, no agent process spawned.
- Operator task variant of the same.
- Existing disk-guard tests keep passing (no behavior change on the happy path).

## Implementation Notes

Reuse the existing blocked-payload / failure path already exercised by genuine denials; the only
change is that exceptions now take that path instead of `:ok`. Log with `action=disk_guard_failed`
and the issue/run context per docs/logging.md.

## Dependencies

- None.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 22 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 686 tests, 2 failures (full suite). Both failures are the PRE-EXISTING
  WorkflowStoreTest concurrency race documented in plans 233/235/236/237 (identical to the plan-232
  control run); NOT introduced by this plan. Isolated runs green: workflow_store + core +
  orchestrator_workspace_disk_guard together = 47 tests, 0 failures.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (orchestrator.ex + new
  test/symphony_elixir/orchestrator_workspace_disk_guard_test.exs)

## Completion Deviations

- `ensure_workspace_disk_available/1` rescue is now fail-closed: any exception produces
  `{:error, %{reason: :disk_guard_evaluation_failed, exception: <struct>, detail: <message>}}`
  and a structured `Logger.error` with `action=disk_guard_failed`. The error flows into the
  existing blocked/failure machinery — no `:ok` pass-through remains.
- Guard module is injectable via `Application.get_env(:symphony_elixir, :workspace_disk_guard_module)`
  (defaults to `WorkspaceDiskGuard`) so tests stub both denial and exceptions.
- Log context distinguishes operator tasks (`run_id=...`) from issues (`issue_context/1`).
- New test file covers all four acceptance scenarios: exception -> issue blocked (no agent spawned,
  log carries action=disk_guard_failed + issue context), exception -> operator task failed
  (reply.status == "failed", no operator runner spawned), normal denial keeps the existing blocked
  path, normal allow proceeds. Test baseline 682 -> 686 (+4).

## Dependencies

