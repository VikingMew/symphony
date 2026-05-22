# 184 Dashboard Nap Control And Queue

## Goal

Add a Dashboard button named `Take a nap` and the runtime queue semantics needed to start exactly one dedicated nap audit task when the runtime is idle, or after currently active work stops.

This plan owns only the operator control, runtime state, queueing, and task lifecycle shell. The dedicated profile, Linear issue creation tool, and audit result/dedup behavior are split into follow-up plans.

## Status

Completed.

## Background

The requested nap feature mixes several concerns:

- Dashboard control and delayed scheduling;
- a dedicated audit-only profile;
- a restricted way to create new Linear backlog issues;
- audit output tracking and duplicate prevention.

Those should not land as one large change. The first atomic slice is the runtime control plane: an operator can request nap, the request is visible, and Symphony starts it only when no other work is active.

## Scope

- Add a Dashboard button labeled `Take a nap` in the runtime controls area.
- Add Dashboard nap status:
  - idle;
  - queued;
  - starting;
  - running;
  - completed;
  - failed.
- Add an orchestrator/runtime API for requesting nap work.
- Model nap as a distinct runtime task kind, for example `:nap_audit`.
- Enforce scheduling semantics:
  - if no local/worker task is active, start the nap task immediately;
  - if active work exists, store one pending nap request;
  - when active work reaches zero, start the pending nap request;
  - repeated clicks while queued/running do not enqueue duplicate work.
- Store enough state to show the latest nap request/run id, status, queued timestamp, started timestamp, finished timestamp, and failure reason.
- Publish observability updates when nap state changes.
- Expose nap state in the Dashboard payload and JSON state API.
- Fail visibly if the nap executor/profile/tool dependencies are not configured yet.

## Out of Scope

- Defining the nap prompt/profile. Owned by plan 185.
- Creating Linear issues. Owned by plan 186.
- Deduplicating discovered audit issues or summarizing created/skipped counts. Owned by plan 187.
- Running nap concurrently with normal agent work.
- Persisting multiple queued nap jobs.
- Automatically scheduling recurring audits.
- Modifying code or documentation.

## Acceptance Criteria

- Dashboard renders a `Take a nap` button.
- Dashboard renders nap state and recent failure/result metadata.
- Clicking `Take a nap` with no active tasks starts one nap runtime task immediately.
- Clicking `Take a nap` while active work is running records one queued request and does not start a task yet.
- When active work stops, a queued nap request starts automatically.
- Clicking repeatedly while queued or running does not create duplicate pending/running nap tasks.
- `Stop listening` does not clear a queued nap request unless the implementation intentionally documents that operator action.
- `Force stop all agents` cancels a running nap task and clears a queued request.
- JSON state API includes a stable nap state object.
- Focused Dashboard and orchestrator tests pass.

## Test Cases

- Dashboard render includes `Take a nap` and shows `nap: idle`.
- Click `Take a nap` when orchestrator snapshot has zero active tasks:
  - nap status becomes starting/running;
  - one nap task shell is recorded.
- Click `Take a nap` when one normal task is running:
  - nap status becomes queued;
  - no nap task starts yet.
- Complete the active task while nap is queued:
  - queued request starts;
  - status changes to starting/running.
- Click twice while queued:
  - only one pending request exists.
- Click twice while running:
  - only one running request exists.
- Force stop while queued:
  - queued request is cleared and visible as cancelled or idle with a flash.
- Force stop while running:
  - running nap task is cancelled through the same cancellation boundary as other runtime work.

## Implementation Notes

- Keep nap queue state in orchestrator/runtime state, not in workflow configuration.
- Prefer a single pending slot over a general-purpose queue until the product needs recurring or multiple audit jobs.
- Nap should not be represented as a fake Linear issue. It is a Symphony runtime task that may later create Linear issues as output.
- Use the same PubSub refresh path as existing Dashboard runtime controls.
- Keep the UI copy plain: `Take a nap queued; will start when active work stops.`
- The runtime task shell should carry a profile id of `nap`, but the actual profile contract is plan 185.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Implemented the operator-control and queue state shell for `nap` and `day_dreaming` together. The task currently records runtime status and summary metadata; a full background Codex audit executor is intentionally not introduced in this slice.

## Dependencies

- [063-listening-control-and-force-stop-agents.md](../completed/063-listening-control-and-force-stop-agents.md)
- [070-dashboard-listening-controls.md](../completed/070-dashboard-listening-controls.md)
- [142-orchestrator-dispatch-policy-boundary.md](../completed/142-orchestrator-dispatch-policy-boundary.md)
- [151-persistence-worker-queue-boundary.md](../completed/151-persistence-worker-queue-boundary.md)
- [185-nap-profile-and-readonly-contract.md](active/185-nap-profile-and-readonly-contract.md)
- [186-nap-linear-issue-create-tool.md](active/186-nap-linear-issue-create-tool.md)
- [187-nap-audit-results-and-dedup.md](active/187-nap-audit-results-and-dedup.md)

## Handoff Notes

Do not let this slice grow into the whole nap feature. Its job is to make the operator request and runtime sequencing reliable. The audit semantics and Linear output path are separate plans.
