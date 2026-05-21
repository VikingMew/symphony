# 131 Worker Page Centralized Mode Explanation

## Goal

Make the Workers page self-explanatory when Symphony is running in `centralized` execution mode.

Instead of showing an apparently empty worker system, the page should clearly state that worker mode is inactive, explain where execution currently happens, and tell operators how worker-backed execution can be enabled.

## Status

Active.

## Background

The current Workers page can show:

```text
Workers
Execution mode: centralized

No workers are registered. Centralized execution remains supported and does not require workers.

Tasks
No worker-backed tasks have been queued yet.
```

This is technically correct but still confusing. An operator can reasonably read it as "a feature is missing" or "the system is not doing work," even though centralized mode is the expected default path.

The original worker design was staged:

- completed plan 008 added worker/task/lease persistence for future external workers;
- completed plan 009 added worker registration;
- completed plan 013 added the `centralized` vs `worker` execution-mode boundary;
- completed plan 030 documented that the current Docker `worker` target is an SSH worker image, not a standalone HTTP worker client process.

In the current runtime, `Config.execution_mode() == :worker` queues worker-backed tasks. Otherwise, the orchestrator uses centralized execution, where the panel directly starts Codex locally or on configured SSH hosts. The Workers page should communicate that distinction.

## Scope

- In `centralized` mode, render the Workers page as a "Worker mode inactive" explanation page rather than an empty registry/task list first.
- Explain the current execution path:
  - Symphony is using centralized execution;
  - issues are dispatched directly by the panel;
  - Codex runs locally unless SSH worker hosts are configured for centralized remote execution;
  - worker-backed task queues are not used in this mode.
- Explain how to enable worker-backed mode:
  - configure `SYMPHONY_EXECUTION_MODE=worker` or the equivalent application config;
  - run/register compatible external workers using the worker API;
  - ensure worker registration token/protocol settings are configured;
  - note that a standalone HTTP worker client/runtime may still be separate from the SSH worker image.
- Keep the existing worker registry/task tables visible when useful:
  - in `worker` mode;
  - or under a secondary/advanced section in centralized mode if historical worker data exists.
- Add links or references to relevant configuration/docs if they exist locally.
- Add tests for the centralized-mode page copy.

## Out of Scope

- Do not implement the standalone HTTP worker runtime.
- Do not change execution mode semantics.
- Do not make centralized mode depend on registered workers.
- Do not remove the existing worker API endpoints.
- Do not remove worker registry/task tables in worker mode.
- Do not alter SSH-host centralized execution behavior.

## Acceptance Criteria

- In `centralized` mode, the Workers page prominently says `Worker mode inactive` or equivalent.
- The page explains that centralized execution is active and that work is dispatched directly by the panel.
- The page explains that worker-backed tasks are only queued in `worker` mode.
- The page explains the high-level steps to enable worker-backed execution.
- The existing empty states no longer read as the primary message in centralized mode.
- In `worker` mode, the page still shows worker registry and task queue information as the primary content.
- The page does not imply that registered workers are required for normal centralized execution.

## Test Cases

- Centralized mode with no workers:
  - page renders `Worker mode inactive`;
  - page renders centralized execution explanation;
  - page does not show only the old empty states.
- Centralized mode with historical workers/tasks:
  - page still explains centralized mode;
  - historical worker/task data is visible only as secondary context or explicitly marked inactive.
- Worker mode with no workers:
  - page renders worker-mode registry/task empty states;
  - page indicates that workers are expected for worker-backed execution.
- Worker mode with workers/tasks:
  - existing tables and task actions still render.
- Existing worker API controller tests continue to pass.

## Implementation Notes

The relevant UI is in `SymphonyElixirWeb.AdminLive` under the `:workers` action. It already has access to `@execution_mode`, `@workers`, and `@tasks`.

Prefer a small conditional rendering structure:

- `@execution_mode == :centralized`:
  - render an explanatory `section-card` first;
  - optionally render worker/task data as inactive/historical context if present.
- `@execution_mode == :worker`:
  - render the existing worker/task registry as the main content.

Use existing UI classes such as `section-card`, `section-title`, `section-copy`, `metric-label`, `status-badge`, and `data-table`.

Be precise in copy:

- "centralized" means panel-owned dispatch, not necessarily all work happens on the same machine;
- centralized mode may still use configured SSH worker hosts;
- "worker mode" here means the HTTP worker API/task queue path.

## Verification

- `mise exec -- mix format`
- Focused LiveView/Admin test for centralized-mode Workers page copy.
- Focused LiveView/Admin test for worker-mode Workers page behavior.
- Existing worker API tests.
- Browser or rendered LiveView evidence showing the centralized-mode page reads as an explanation, not as an empty failure state.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Completed plan 008 for worker/task/lease data model.
- Completed plan 009 for worker registration API.
- Completed plan 013 for execution-mode dispatch.
- Completed plan 030 for Docker mode documentation and the distinction between SSH worker image and standalone HTTP worker runtime.

## Handoff Notes

This is an operator-experience fix, not a worker runtime feature. The page should make the inactive worker queue understandable while preserving centralized execution as a first-class supported mode.
