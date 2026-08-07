# 151 - Persistence Worker Queue Boundary

Status: Completed

## Problem

`SymphonyElixir.Persistence` mixes project/workflow persistence, runtime issue/run/event persistence, users/tracker configs, and worker queue protocol operations in one context module.

The worker queue section includes registration, sessions, task enqueue/claim, heartbeats, lease expiry, cancellation, requeue, worker task events, capability matching, and task/run transition side effects. This is a separate domain from workflow/project persistence.

## Goal

Extract worker queue persistence into a focused context such as `SymphonyElixir.Persistence.WorkerQueue`.

The public persistence provider can keep delegating for compatibility, but worker queue invariants should be tested at the worker queue boundary.

## Plan

1. Inventory worker-related public and private functions in `persistence.ex`.
2. Define a worker queue API that preserves current call shapes for controllers/orchestrator.
3. Move worker registration, task leasing, heartbeat, cancellation, requeue, and worker event transitions into the new module.
4. Keep shared Ecto schemas unchanged.
5. Leave compatibility delegators in `Persistence` only if the persistence provider behavior requires them.
6. Add focused tests for lease claim ordering, capability matching, stale expiry, cancellation commands, terminal event release, and run transition side effects.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/persistence/worker_queue_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
  - Result: `47 tests, 0 failures`.
- `rg -n "register_worker|claim_task|heartbeat|expire_stale_worker_state|cancel_task|requeue_task|record_worker_task_event|TaskLease|WorkerSession|defp .*worker|capability_match|active_worker_session" lib/symphony_elixir/persistence.ex lib/symphony_elixir/persistence test/symphony_elixir/persistence/worker_queue_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
  - Result: worker queue implementation and worker private helpers now live in `Persistence.WorkerQueue`; `Persistence` keeps public compatibility delegators.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

The focused worker queue tests intentionally do not start a real Repo, matching the current test boundary that default tests use fake persistence. They cover worker queue configuration, no-Repo behavior, and `Persistence` compatibility delegation; existing web fake persistence tests cover the worker API route contract without a real database.
