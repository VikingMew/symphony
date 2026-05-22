# 183 Dashboard Refine-Only Listening Control

## Goal

Add a Dashboard control that lets an operator start listening only for refinement work, without dispatching implementation, merge, or other non-refinement agent phases.

The operator-facing behavior should be explicit: the Dashboard should show whether Symphony is not listening, listening for all configured active work, or listening in refine-only mode.

## Status

Completed.

## Background

The Dashboard currently exposes runtime controls for:

- Start listening;
- Stop listening;
- Force stop all agents.

Those controls operate on a binary listening state. When listening is enabled, dispatch uses the configured workflow active states and profiles. That is too broad for an operator who wants to let Codex only refine new tasks while preventing implementation or merge work from starting.

This is especially useful when the team wants to run a triage/refinement pass, review the produced plans/comments, and only later allow implementation stages.

The feature must not mutate workflow configuration as a shortcut. Temporarily editing `active_states` or profile routes would make the runtime state unclear, would be hard to audit, and could leave the system in a surprising configuration after restart or operator handoff.

## Scope

- Add a runtime listening mode distinct from the existing listening boolean:
  - `not_listening`;
  - `listening_all`;
  - `listening_refine_only`.
- Add a Dashboard button for refine-only listening near the existing runtime controls.
- Update the Dashboard status copy/badge so the current mode is visible.
- Route the new button to a clear orchestrator API, for example `start_refine_only_listening/1` or `start_listening(mode: :refine_only)`.
- Keep `Stop listening` as the single way to disable both all-work listening and refine-only listening.
- Ensure force-stop behavior remains unchanged except for status display after listening is stopped.
- Filter candidate dispatch in refine-only mode to refinement work only.
- Define "refinement work" from workflow/profile routing rather than a hard-coded English state name where possible:
  - prefer states routed to the `refinement` profile;
  - fall back to a documented canonical `Refining` state only if the current workflow has no route metadata.
- Expose the listening mode in the dashboard payload and JSON state API.
- Persist or emit an event when listening mode changes so operators can audit why only refinement work is being dispatched.
- Add focused tests for Dashboard rendering, event handling, orchestration state, and dispatch filtering.

## Out of Scope

- Changing default workflow states.
- Adding a full multi-select state filter UI.
- Persisting listen mode across process restarts.
- Changing Linear state transitions or profile prompt content.
- Starting implementation automatically after refinement completes.
- Changing worker registration or worker task lease semantics beyond respecting the dispatch filter.

## Acceptance Criteria

- Dashboard renders a clear runtime mode:
  - `Listening: disabled`;
  - `Listening: all active work`;
  - `Listening: refinement only`.
- Dashboard includes a refine-only listening button.
- Clicking the refine-only button enables listening and sets runtime mode to refinement-only.
- In refine-only mode, new dispatches are limited to issues whose current state routes to the refinement profile.
- In refine-only mode, issues in implementation, review, merge, or other active states are not dispatched.
- `Start listening` still enables normal all-active-state dispatch.
- `Stop listening` disables both normal and refine-only listening.
- `Force stop all agents` continues to stop active work and disable listening.
- The JSON state API exposes the current listening mode.
- Existing listeners and workers do not need to be registered for centralized mode.
- Focused LiveView and orchestrator tests pass.

## Test Cases

- Dashboard snapshot with mode `not_listening` renders disabled status and the refine-only button.
- Clicking refine-only listening in Dashboard calls the orchestrator and updates rendered status to refinement only.
- Clicking Start listening after refine-only mode switches the mode to all active work.
- Clicking Stop listening after refine-only mode switches the mode to disabled.
- Orchestrator dispatch policy with refine-only mode dispatches a `Refining` or refinement-profile issue.
- Orchestrator dispatch policy with refine-only mode skips `Ready`, `In Progress`, `Ready to Merge`, and `Merging` issues even if those states are otherwise active.
- Worker-task queue mode respects the same refine-only filter before enqueuing tasks.
- JSON state API includes a stable field such as `polling.listening_mode`.

## Implementation Notes

- Keep the mode in orchestrator runtime state, not in database workflow settings.
- Prefer modeling the mode as an atom internally and serializing it as a stable string at API/presenter boundaries.
- Avoid naming the UI "only listen refine" if possible; "Listen refinement only" is clearer.
- Reuse the existing Dashboard runtime-control section and button styles.
- Reuse existing `ObservabilityPubSub` refresh behavior so Dashboard updates immediately after a mode change.
- If the current dispatch code only has a boolean listening gate, introduce a small filtering function close to dispatch candidate selection rather than scattering mode checks through the orchestrator.
- The profile route lookup should use normalized state names so Linear capitalization does not matter.
- If no refinement-routed states exist, the UI should not silently dispatch nothing. It should either:
  - disable the refine-only button with an explanatory tooltip/status, or
  - use the documented fallback state and surface that fallback in status/debug copy.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- The refine-only affordance uses the documented `Refining` fallback when no workflow state is routed to the `refinement` profile; the UI does not currently render a separate fallback warning because the fallback is intentional and visible through persisted mode-change events plus dispatch behavior.

## Dependencies

- [063-listening-control-and-force-stop-agents.md](../completed/063-listening-control-and-force-stop-agents.md)
- [070-dashboard-listening-controls.md](../completed/070-dashboard-listening-controls.md)
- [036-orchestrator-profile-activity-dispatch.md](../completed/036-orchestrator-profile-activity-dispatch.md)
- [155-dashboard-live-presentation-boundary.md](../completed/155-dashboard-live-presentation-boundary.md)

## Handoff Notes

The core safety requirement is that refine-only listening is an operational runtime mode, not a workflow edit. Operators should be able to tell at a glance that Symphony is intentionally ignoring implementation/merge candidates until normal listening is restored.
