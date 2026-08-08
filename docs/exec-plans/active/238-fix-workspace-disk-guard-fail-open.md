# 238 Fix workspace disk guard fail-open

## Goal

Stop the workspace disk-safety gate from passing when its own evaluation fails.

## Status

Active.

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

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

