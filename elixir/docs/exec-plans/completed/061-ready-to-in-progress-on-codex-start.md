# 061 Ready To In Progress On Codex Start

## Goal

Move `Ready` issues to `In Progress` automatically after Symphony successfully starts the Codex session, so Linear reflects that implementation work has actually begun.

## Status

Completed.

## Background

The current implementation profile can dispatch both `Ready` and `In Progress` issues, but the runtime does not automatically transition `Ready -> In Progress`. The transition is only available to Codex through `linear_task_update` after Codex starts.

That creates an operator-visible mismatch:

- a `Ready` task can be claimed by Symphony and spend time preparing workspace or running Codex;
- Linear may still show `Ready`;
- if workspace bootstrap fails, the task correctly never entered implementation, but if workspace bootstrap succeeds, the state still may not reflect active work until Codex chooses to request the transition.

The desired contract is:

1. `Ready` means human-confirmed and eligible for implementation.
2. `In Progress` means Symphony has prepared the workspace and successfully started Codex for implementation.
3. Workspace/bootstrap failure must not move the task to `In Progress`.
4. Codex startup failure must not move the task to `In Progress`.
5. If the backend cannot perform `Ready -> In Progress` after Codex starts, the run should stop before sending the first task turn because the workflow state would lie.

Recent production-like logs also showed another diagnostic gap: structured project bootstrap logs are emitted as `hook=after_create`, even when the command is the generated clone/setup path. That makes failures look like custom lifecycle hooks when they are actually project bootstrap.

## Scope

- Add a backend-owned implementation-start transition after `AppServer.start_session/2` succeeds and before the first Codex turn is sent.
- Only attempt this transition when the current issue state is exactly `Ready` and the routed workflow profile is `implementation`.
- Request the transition through the restricted Linear/task boundary or an equivalent backend helper that enforces:
  - current issue id matches the running issue;
  - transition is allowed by `workflow.allowed_transitions`;
  - target state exists in Linear;
  - actor is backend/Symphony, not Codex prompt logic.
- Refresh or update the in-memory issue state to `In Progress` before building the first Codex prompt.
- If the issue is already `In Progress`, skip the transition and continue normally.
- If the issue is in another implementation-routed state, do not force it to `In Progress`.
- If workspace preparation fails, do not request `Ready -> In Progress`.
- If Codex session startup fails, do not request `Ready -> In Progress`.
- If `Ready -> In Progress` fails after Codex session startup, stop the Codex session, record a clear run failure, and do not send the first task turn.
- Improve logging so generated project bootstrap and custom `hooks.after_create` are distinguishable.
- Update docs to say `Ready -> In Progress` is backend-owned after Codex session startup, not Codex-owned.
- Add focused tests for success, skip, transition failure, and bootstrap failure behavior.

## Out of Scope

- Moving issues to `In Progress` before workspace preparation.
- Moving issues to `In Progress` before Codex session startup succeeds.
- Retrying or compensating Linear transitions after the first Codex task turn has started.
- Changing human review transitions.
- Implementing merge automation.
- Fixing slow or interactive git clone behavior beyond better logs.
- Full allowed-transition editor UI.

## Acceptance Criteria

- [x] A `Ready` issue that successfully creates/prepares a workspace and starts Codex is transitioned to `In Progress` before the first Codex task turn.
- [x] The first Codex prompt sees the refreshed `In Progress` issue state.
- [x] A workspace/bootstrap failure leaves the issue in `Ready` and does not request `In Progress`.
- [x] A Codex startup failure leaves the issue in `Ready` and does not request `In Progress`.
- [x] An issue already in `In Progress` starts Codex without an extra transition request.
- [x] A failed `Ready -> In Progress` request stops the run before the first Codex task turn and records a clear error.
- [x] Transition logic uses workflow policy rather than hard-coded unconditional state changes.
- [x] Logs distinguish generated project bootstrap from custom `hooks.after_create`.
- [x] Docs no longer describe `Ready -> In Progress` as something Codex may optionally request at implementation start.
- [x] Relevant tests pass.

## Test Cases

- Ready happy path:
  - fake workspace creation succeeds;
  - fake Codex session startup succeeds;
  - fake transition helper receives `Ready -> In Progress`;
  - first fake Codex turn receives issue state `In Progress`.
- Workspace failure path:
  - workspace creation returns an error;
  - no transition request is made;
  - Codex does not start.
- Codex startup failure path:
  - workspace creation succeeds;
  - Codex session startup returns an error;
  - no transition request is made.
- Transition failure path:
  - workspace creation succeeds;
  - Codex session startup succeeds;
  - transition helper returns `linear_state_not_found`, `transition_not_allowed`, or API error;
  - Codex session is stopped;
  - first Codex task turn is not sent and the run reports the transition error.
- Already in progress path:
  - issue state is `In Progress`;
  - no transition request is made;
  - Codex starts normally.
- Non-implementation profile path:
  - issue state routes to refinement or merge;
  - no `Ready -> In Progress` logic runs.
- Logging path:
  - generated clone/setup emits a project-bootstrap log label;
  - custom `hooks.after_create` emits a hook log label.

## Implementation Notes

- The transition should live in the runtime boundary around `AgentRunner.run_codex_turns/5`, after `AppServer.start_session/2` returns `{:ok, session}` and before `do_run_codex_turns/8` sends the first prompt.
- Prefer adding an injectable transition function for tests rather than coupling tests to real Linear.
- Reuse existing policy helpers where possible:
  - `Config.workflow_profile_for_state/1`
  - `Config.workflow_allowed_updates/1`
  - `workflow.allowed_transitions`
- Avoid asking Codex to perform this startup transition. Codex should still use `linear_task_update` for completion transitions such as `In Progress -> Needs Implementation Review`.
- If an issue lacks a stable Linear id, fail clearly when the workflow requires the backend transition; do not send the first Codex task turn from `Ready`.
- Logging should not expose secrets or full command strings beyond current safe output behavior.

## Verification

- `mise exec -- mix format` passed.
- `mise exec -- mix lint` passed.
- `mise exec -- mix test test/symphony_elixir/core_test.exs` passed.
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs` passed.
- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs` passed.
- `git diff --check` passed.
- `mise exec -- make all` passed setup, build, format check, lint, and coverage. Coverage was 83.32% with 277 tests, 0 failures, and 2 skipped. The command failed at the final Dialyzer stage with existing project-wide warnings in `codex/app_server.ex`, `linear/diagnostics.ex`, `orchestrator.ex`, `persistence.ex`, `status_dashboard.ex`, `workflow.ex`, and `workflow_validator.ex`; those warnings are outside this plan's behavioral change.

## Completion Deviations

The delivered transition is backend-owned in `AgentRunner` after `AppServer.start_session/2` succeeds and before the first Codex turn. Because the existing workflow transition schema does not yet have a separate `symphony` actor, the policy check accepts the existing `codex` actor value for `Ready -> In Progress` as well as a future `symphony` value, while the transition itself is still executed by Symphony rather than by the Codex prompt.

## Dependencies

- Existing restricted Linear task update/transition boundary.
- Existing profile routing from workflow state to implementation profile.
- Existing workspace clean-start and project-bootstrap ordering from plans 058 and 059.

## Handoff Notes

This plan intentionally makes `In Progress` mean "Codex session has started and Symphony has taken implementation ownership", not merely "workspace exists" or "Codex eventually decided to update Linear." That keeps failed bootstrap and failed Codex startup attempts visible as `Ready` failures instead of falsely marking work as underway.
