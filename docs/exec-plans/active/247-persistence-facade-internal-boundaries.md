# 247 Persistence façade internal boundaries (one-way deps)

## Goal

Make the Persistence internal contexts depend only on Repo/same-layer modules — never back on the
parent façade — and align error contracts with plan 239's typed reads.

## Status

Active.

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

