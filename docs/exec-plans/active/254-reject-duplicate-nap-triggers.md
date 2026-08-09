# 254 Reject duplicate nap / day_dreaming triggers while one is running

## Goal

Prevent overlapping operator runs: while a nap (or day_dreaming) run is already **running** or
**queued** for a project, a new trigger of the same profile must be rejected with an explicit
error, instead of silently starting a second audit of the same repository that duplicates every
issue.

## Background

On 2026-08-09 two nap runs (b1a1fe03 and 1b12f47b) audited the same koroni repository 24 minutes
apart and each created a full round of Linear issues (53 + 23 = 76 issues, KRN-23..KRN-98). The
second round duplicated roughly 20 findings already created by the first round (same file/line
evidence, reworded titles), because the orchestrator happily starts a new operator run even when
one for the same profile/project is already active.

This plan adds a mutual-exclusion guard at the request boundary: one active operator run per
profile per project. It does not add issue-level deduplication (a separate concern; the audit
prompt and issue_create tool are the right layer for that).

## Design

### 1. Orchestrator request gate

In `request_operator_task(kind, project_id)` (orchestrator.ex), before resolving the project and
workflow, check the current operator task state for the requested `kind`:

- If an operator task of the same `kind` is `:running` → reject with
  `{:error, {:operator_task_busy, kind}}` (do not queue).
- If an operator task of the same `kind` is `:queued` → reject with
  `{:error, {:operator_task_already_queued, kind}}` (do not double-queue).
- Otherwise proceed as today.

The state lookup must read the same in-memory operator task map that `:snapshot` exposes
(`operator_tasks.nap.status` / `operator_tasks.day_dreaming.status`), so the gate is consistent
with what the dashboard shows.

### 2. Explicit failure surface

The rejection reason must be:

- logged at error level with issue/session context (per docs/logging.md),
- returned from the request call so callers (dashboard LiveView, tests) can render it,
- surfaced in the dashboard flash as "A nap is already running for this project" / "A nap is
  already queued for this project".

### 3. Rate-limit gate independence

Do not overload the existing rate-limit gate (`rate_limit_gate`). The busy gate is about operator
run exclusivity, not rate limits; keep them separate but both checked.

## Acceptance criteria

1. `request_operator_task(:nap, project)` while a nap run is in progress → `{:error,
   {:operator_task_busy, :nap}}`, no new run started, no events emitted.
2. `request_operator_task(:nap, project)` while a nap is queued → `{:error,
   {:operator_task_already_queued, :nap}}`.
3. `request_operator_task(:day_dreaming, project)` while a nap runs → **allowed** (different
   profile).
4. After the active nap completes, `request_operator_task(:nap, project)` succeeds again.
5. Dashboard shows the rejection as a flash message; the existing "Request nap" button behavior
   is otherwise unchanged.
6. Existing tests for operator task lifecycle still pass; new tests cover: busy rejection,
   queued rejection, cross-profile allowance, and post-completion re-allowance.

## Out of scope

- Issue-level deduplication (checking whether a finding already exists as an open Linear issue
  before creating it). That is a follow-up plan for `issue_create` / the nap prompt.
- Cleanup of the duplicated issues created on 2026-08-09 (done manually by the operator).
