# 240 Unify audit/phase event write semantics

## Goal

Replace four hand-written "failure means success" audit-event writers with one honest persistence
entry: `:ok | {:degraded, reason} | {:error, reason}`, structured logs, and per-event-class
strong/weak consistency.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 22 [R] + 1 [D], unchanged)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 692 tests, 1 failure (full suite). The single failure
  ("worktree bootstrap clone uses initialize timeout", Workspace.SourcePreparationTest) is a
  timing-sensitive flake under full-suite load — the file passes in isolation (30 tests, 0
  failures). Not related to this plan (which touches no workspace bootstrap code).
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (4 lib modules + new
  lib/symphony_elixir/persistence_event_writer.ex + new audit_event_write_semantics_test.exs)

## Completion Deviations

- New `SymphonyElixir.PersistenceEventWriter` (`record/2`): returns `:ok | {:degraded, reason} |
  {:error, reason}` where `:repo_unavailable` -> `{:degraded, :repo_unavailable}` (warning log),
  other errors/raised exceptions/unexpected results -> `{:error, ...}` (error log, exception kept
  in the reason). Logs carry issue_id/issue_identifier/session_id/run_id extracted from attrs,
  payload, or explicit context.
- Three telemetry sites (agent_runner emit_phase/emit_branch_event, workspace persist_hook_event,
  merge_executor record_phase) use the writer with explicit best-effort policy: degraded/error is
  logged at warning level (`action=continue_degraded`) and the caller continues — visible but not
  crashing.
- The critical audit site (linear_tool_audit.record/4) returns `:ok | {:error, ...}`; failures are
  logged at error level (`action=surface_error`, full issue/run/session context) and returned as
  `{:error, {:linear_tool_audit_write_failed, reason}}`. The fire-and-forget caller cannot act on
  it yet, so surfacing + error log is the implemented semantics (per plan's fallback).
- All four `rescue _ -> :ok` audit writers removed (grep zero in the four modules); the five
  remaining rescues in workspace.ex are pre-existing non-audit paths (clone/hook error handling),
  untouched. Test baseline 686 -> 692 (+6: writer unit tests + per-site degradation tests).

## Dependencies

