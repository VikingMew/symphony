# 247 Persistence façade internal boundaries (one-way deps)

## Goal

Make the Persistence internal contexts depend only on Repo/same-layer modules — never back on the
parent façade — and align error contracts with plan 239's typed reads.

## Status

Completed.

## Background

Source: REFACTOR_REVIEW.md M7. The parent façade `Persistence` delegates to
`Persistence.WorkflowStore` / `Persistence.WorkerQueue`, but the children call back into the
façade: `repo_available?/0` (persistence/workflow_store.ex:9-11, 15-57;
persistence/worker_queue.ex:7-12, 47-80) and `default_project/0` via the parent
(worker_queue). xref's length-6 persistence/workflow cycle includes these reverse edges plus the
Workflow runtime/package mix. `PersistenceProvider` is a fine test seam — the problem is children
calling the parent API. Violates Linus "remove complexity" (unclear dependency direction) and
Carmack (cycles make error contracts and init order harder to reason about).

## Scope

- Internal contexts depend on Repo / same-layer contexts only; repo availability lives at the
  narrow owner of the Repo lifecycle; `WorkerQueue` reads `default_project` from the same-layer
  `Persistence.WorkflowStore` directly.
- No second façade. `Persistence` remains the external façade.
- Land AFTER plan 239's typed read contract; reuse its error types instead of introducing new ones.

## Out of Scope

- Re-architecting persistence storage; changing external façade callers.
- Reordering modules purely to make the xref graph green (only the reverse edges are removed).

## Acceptance Criteria

- xref no longer reports the persistence reverse edges (children -> parent); the
  persistence/workflow cycle shrinks or disappears.
- All persistence-backed tests green (fake-persistence and stubbed-fault suites).

## Test Cases

- Existing persistence/workflow_store/worker_queue suites.
- xref cycle check.

## Implementation Notes

Pair with plan 239: the typed-contract migration and this boundary cleanup share the same files;
sequence this one second so error types are already settled.

## Dependencies

- Plan 239 (typed read contract) — do NOT start before 239 lands.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D] — READABILITY IMPROVED, was 22 [R] before this plan)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 701 tests, 1 failure (full suite). The single failure is the KNOWN flaky
  OrchestratorStatusTest timeout (documented as flaky in the plan baseline); isolated run green:
  orchestrator_status + persistence/workflow_store + read_errors = 49 tests, 0 failures.
- `mise exec -- mix xref graph --format cycles` — reported; the persistence length-6 cycle's
  children->parent reverse edges are GONE (grep "Persistence." in lib/symphony_elixir/persistence/*.ex
  -> zero hits). The cycle that remains consists of legitimate parent->child delegates plus the
  Workflow<->WorkflowStore bidirectional pair, which plan 246 removes.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (persistence/worker_queue.ex,
  persistence/workflow_store.ex; 2 files, +30/-26)

## Completion Deviations

- `Persistence.WorkflowStore`: all 10+ `Persistence.repo_available?()` call sites replaced with a
  private `repo_available?/0` (`Process.whereis(Repo) != nil`) — the narrow owner of Repo
  lifecycle, no parent-façade hop.
- `Persistence.WorkerQueue`: same private `repo_available?/0`; `Persistence.default_project()` ->
  same-layer `WorkflowStore.default_project()` (the parent's delegate target); `Persistence` alias
  removed from both modules.
- No second façade; `Persistence` remains the external façade with unchanged public surface
  (external callers untouched). Plan 239's typed read contract reused as-is (no new error shapes).
- Credo readability 22 -> 20 [R] (the removed reverse calls dropped two redundant-alias/style
  findings); 0 [F] maintained. Test baseline unchanged at 701.

