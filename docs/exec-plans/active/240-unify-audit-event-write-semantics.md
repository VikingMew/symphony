# 240 Unify audit/phase event write semantics

## Goal

Replace four hand-written "failure means success" audit-event writers with one honest persistence
entry: `:ok | {:degraded, reason} | {:error, reason}`, structured logs, and per-event-class
strong/weak consistency.

## Status

Active.

## Background

Source: REFACTOR_REVIEW.md H3. Four call sites invoke `record_event/1` (or its peer) and return
`:ok` unconditionally, ignoring `{:error, reason}` and swallowing exceptions with
`rescue _ -> :ok`:
- `agent_runner.ex:534-558, 566-585` (phase events)
- `workspace.ex:971-990, 1004-1026` (workspace hook events)
- `merge_executor.ex:195-215` (merge phase events)
- `codex/linear_tool_audit.ex:14-52` (restricted tool audit)
The orchestrator already has the reference semantics (orchestrator.ex:2778-2837): distinguishes
`:repo_unavailable`, logs structured failure, refuses to swallow unexpected results. The four copies
mean hooks/merges/audits/agent phases can execute with NO record and NO degradation marker.
Violates AGENTS.md "Explicit errors over silent tolerance" and Linus "remove complexity" (same
error policy written four times).

## Scope

- Extract ONE narrow persistence-event writer (not a general "error framework"): returns
  `:ok | {:degraded, reason} | {:error, reason}` with structured logs and issue/run/session
  context (docs/logging.md).
- Re-point the four call sites; each chooses best-effort EXPLICITLY per event class:
  - telemetry/phase events: best-effort but visibly degraded (`{:degraded, reason}` logged);
  - critical audit events (restricted-tool audit, merge outcome): failure makes the current action
    fail (`{:error, reason}` propagated).
- No global boolean toggle; strong/weak policy is declared per event class at the call site.

## Out of Scope

- Building a generic telemetry framework; changing event storage schema.
- Plan 232's redaction layer (already unified, unrelated).

## Acceptance Criteria

- No `rescue _ -> :ok` audit writers remain in the four modules (grep acceptance).
- A stubbed persistence failing on `record_event` produces a visible `{:degraded, ...}` or
  `{:error, ...}` (never silent `:ok`), per event class.
- Critical-audit events abort their action on write failure; telemetry events degrade visibly.

## Test Cases

- Per call site: persistence raises -> degraded/error outcome asserted; no silent success.
- Orchestrator reference behavior unchanged (existing tests).

## Implementation Notes

Adopt the orchestrator's semantics as the single implementation; keep per-call-site
strong/weak policy explicit in the calling module (documented in a comment, not a config key).

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

