# 070 Dashboard Listening Controls

## Goal

Move the listening controls from the runs page to the dashboard landing page,
including the current listening status, so the operator can see and control the
runtime polling mode from the primary operations screen.

## Status

Completed.

## Background

Plan 063 added explicit controls for starting/stopping listening and force
stopping all active agents. The current UI exposes those controls on the
persisted runs page. Operationally, listening is a runtime-level control, not a
run-list concern, and the dashboard is already the place operators use to watch
current runtime state.

The move must include both:

- action buttons: start listening, stop listening, force stop all agents;
- current status display: listening enabled/disabled.

Moving only the buttons is incomplete because the operator would be acting
without seeing the current runtime mode.

## Scope

- Render listening status on the dashboard page using the existing dashboard
  payload or orchestrator snapshot.
- Render the existing listening action buttons on the dashboard page:
  - Start listening;
  - Stop listening;
  - Force stop all agents.
- Wire the dashboard buttons to the existing Orchestrator APIs:
  - `start_listening/1`;
  - `stop_listening/1`;
  - `force_stop_all/1`.
- Refresh dashboard state after each action so the status changes immediately.
- Remove the listening status/actions from the runs page to avoid duplicated
  runtime controls.
- Preserve the force-stop confirmation text and existing rollback behavior.
- Add focused LiveView coverage proving the dashboard shows status and action
  buttons, and that a click updates the status.

## Out of Scope

- Changing Orchestrator listening semantics.
- Changing force-stop rollback logic.
- Adding new database tables or persisted settings.
- Redesigning the whole dashboard layout.
- Moving unrelated run detail or event controls.

## Acceptance Criteria

- Dashboard renders `Listening: enabled` or `Listening: disabled`.
- Dashboard renders Start listening, Stop listening, and Force stop all agents.
- Clicking Start listening on the dashboard calls the configured orchestrator
  and updates the rendered status to enabled.
- Clicking Stop listening on the dashboard calls the configured orchestrator and
  updates the rendered status to disabled.
- Force stop remains available on the dashboard with the existing confirmation.
- Runs page no longer contains the listening status/actions.
- Existing API payload still includes polling/listening status.
- Focused LiveView tests pass.
- `mise exec -- mix format` passes.
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs` passes.

## Test Cases

- Static dashboard snapshot with `polling.listening? == false` renders
  `Listening: disabled`.
- Start listening event against a test orchestrator changes the dashboard
  status to `Listening: enabled`.
- Stop listening event changes the dashboard status back to
  `Listening: disabled`.
- Runs page render does not include the listening control button text.

## Implementation Notes

- Prefer using `@payload.polling.listening?` on `DashboardLive` rather than
  adding a second independent snapshot call.
- Keep the event names aligned with the existing AdminLive handlers unless
  there is a strong reason to rename them.
- If test support uses `StaticOrchestrator`, extend it to support listening
  calls in tests instead of using the production Orchestrator process.
- Keep visual treatment consistent with existing dashboard sections and buttons.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/web_fake_persistence_test.exs` passed: 26 tests, 0 failures.
- `mise exec -- mix lint` passed.
- `mise exec -- mix test` passed: 290 tests, 0 failures, 2 skipped.

## Completion Deviations

None.

## Dependencies

- Existing runtime control APIs from
  [063-listening-control-and-force-stop-agents.md](../completed/063-listening-control-and-force-stop-agents.md).
- Existing dashboard payload polling field from `SymphonyElixirWeb.Presenter`.

## Handoff Notes

This is a UI relocation, not a runtime behavior change. The dashboard should
become the single visible place for listening controls, while `/runs` remains a
historical run list.
