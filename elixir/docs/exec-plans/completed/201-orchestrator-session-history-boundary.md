# 201 Orchestrator Session History Boundary

## Goal

Move session-history construction and presentation shaping out of `Orchestrator` so orchestration logic no longer owns historical event formatting.

## Status

Completed.

## Background

`lib/symphony_elixir/orchestrator.ex` remains over 2,000 lines. Completed plan 193 owns operator tasks as first-class runs, so this plan deliberately avoids that area.

One remaining separable concern is session-history assembly: collecting, normalizing, and shaping Codex events for dashboard/run-history display. That work is not core scheduling or state-machine logic, and it makes orchestrator changes harder to reason about.

## Scope

- Identify functions in `Orchestrator` that build session history, event summaries, or display-shaped history payloads.
- Move pure construction logic into a focused module, for example `Orchestrator.SessionHistory` or an existing run-history boundary.
- Keep orchestrator responsible for calling the boundary at the right lifecycle point.
- Preserve event payload shape for dashboard and run-detail consumers.
- Add focused tests for the extracted builder.

## Out of Scope

- Operator-run schema changes owned by completed plan 193.
- Changing Codex event persistence.
- Redesigning dashboard or run-detail presentation.
- Splitting unrelated dispatch, queue, or Linear rollback logic.

## Acceptance Criteria

- Session-history shaping is no longer implemented inline in `Orchestrator`.
- Extracted logic is mostly pure and testable without a running GenServer.
- Existing orchestrator status and run-history tests pass.
- Dashboard/run-detail payloads remain backwards compatible.
- `Orchestrator` line count drops for a coherent ownership reason.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/message_humanizer_test.exs`
- `wc -l lib/symphony_elixir/orchestrator.ex lib/symphony_elixir/orchestrator/*.ex`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 116 for readable run detail session history.
- Completed plan 141 for run detail agent execution summary.
- Completed plan 142 for orchestrator dispatch policy boundary.
- Completed plan 193 for operator runs, which may add new session-history inputs.

## Handoff Notes

Keep the orchestrator as the coordinator. It should not also be the formatter for historical Codex updates.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

