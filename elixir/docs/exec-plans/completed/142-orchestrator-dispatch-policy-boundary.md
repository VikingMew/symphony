# 142 - Orchestrator Dispatch Policy Boundary

Status: Completed

## Problem

`SymphonyElixir.Orchestrator` still owns issue selection, candidate filtering, state slot checks, worker routing, priority sorting, and dispatch revalidation inside the GenServer module.

The code around `choose_issues/2`, `sort_issues_for_dispatch/1`, `should_dispatch_issue?/4`, worker slot selection, and retry revalidation is mostly policy logic. Keeping it inside the process module makes scheduling changes hard to test without constructing full orchestrator state and timer behavior.

## Goal

Extract dispatch policy into a pure boundary that answers:

- which issues are candidates;
- how candidates are sorted;
- whether an issue can dispatch in the current state;
- which worker host should receive work, if any.

The orchestrator should keep ownership of timers, process state, and side effects.

## Plan

1. Inventory dispatch-related helpers in `orchestrator.ex`, including test-only wrappers.
2. Introduce a small module such as `SymphonyElixir.Orchestrator.DispatchPolicy`.
3. Move pure candidate filtering, priority sorting, active/terminal state checks, state slot checks, and worker host selection into the new module.
4. Keep `dispatch_issue/4` and actual worker/local side effects in `Orchestrator`.
5. Replace test-only wrappers with direct tests against the policy module.
6. Verify the extracted policy preserves ordering, state limits, worker routing, and non-terminal blocker behavior.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator/dispatch_policy_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/core_test.exs`
  - `125 tests, 0 failures`
  - Covers direct dispatch-policy sorting, dispatch eligibility, blocker checks, revalidation, state limits, worker host capacity, and existing orchestrator regressions.
- `rg -n "revalidate_issue_for_dispatch_for_test|sort_issues_for_dispatch_for_test|should_dispatch_issue_for_test|select_worker_host_for_test|candidate_issue\\?|ready_issue_blocked_by_non_terminal\\?|worker_slots_available\\?|state_slots_available\\?|retry_candidate_issue\\?" lib/symphony_elixir/orchestrator.ex test`
  - No test-only dispatch wrappers or private policy helpers remain in `Orchestrator`.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
