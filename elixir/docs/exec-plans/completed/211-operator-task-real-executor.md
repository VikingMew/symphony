# 211 Operator Task Real Executor

## Goal

Make `nap` and `day_dreaming` operator tasks execute real Codex runs instead of stopping at a synthetic `running` row.

When an operator starts `Take a nap` or `Day dreaming`, Symphony should prepare a workspace, start the configured Codex profile, stream session updates, persist tokens and session history, and complete/fail/stop the run through the same observable lifecycle as issue-backed work.

## Status

Completed.

## Background

Plans 184-188 introduced the operator controls and their intended prompts. Plan 193 then made operator tasks visible as first-class runs without requiring a Linear issue id.

The current implementation still has a critical execution gap. `start_operator_task/2` creates a persisted `RunRecord` and inserts a `state.running` entry, but that entry has:

- `pid: nil`;
- `ref: nil`;
- `workspace_path: nil`;
- `session_id: nil`;
- `codex_app_server_pid: nil`;
- token counters set to `0`;
- only one session-history item: `operator_task.started`.

No supervised process is spawned, no workspace is prepared, no repository sync occurs, no Codex app session starts, and no profile prompt is executed. The Dashboard therefore shows a run that looks active but cannot make progress.

This also creates a scheduler problem. `runtime_busy?/1` currently treats any `state.running` entry as runtime occupancy. A synthetic operator entry makes the runtime look permanently busy, blocking queued operator tasks and potentially normal dispatch until a force stop or process restart clears it.

The fix is to make operator runs use a real execution path, not to hide the row or special-case the Dashboard.

## Scope

- Introduce a real operator-run execution path for `nap` and `day_dreaming`.
- Start a monitored process or task when an operator task transitions to `running`.
- Give the running entry real lifecycle fields:
  - `pid` / `ref` for cancellation and `DOWN` handling;
  - `workspace_path` after workspace preparation;
  - `session_id` once Codex starts;
  - Codex app server pid when available;
  - token and turn counters from Codex updates.
- Reuse the existing workspace source strategy for operator runs:
  - pull/update the repository source when the strategy requires it;
  - create an isolated workspace/worktree for the operator run;
  - apply existing pre-start hooks and workspace disk guard policies where they apply to normal runs.
- Build the operator prompt from the configured `nap` or `day_dreaming` profile instead of embedding a separate ad hoc prompt in the orchestrator.
- Stream Codex updates into the same session-history, event, rate-limit, token, and run-detail persistence paths used by issue-backed runs.
- Persist terminal states:
  - `completed` when the operator run finishes successfully;
  - `failed` with a useful reason when workspace, prompt, Codex, or Linear tool execution fails;
  - `stopped` when force stop cancels it.
- Remove the permanent-busy failure mode:
  - a running operator entry must correspond to a real live process, or to a recoverable persisted run being reconciled;
  - stale operator entries with no process/session must be marked failed or stopped with explicit evidence.
- Keep `operator_tasks` only as button/queue state, not as the execution source of truth.

## Out of Scope

- Changing the `nap` audit prompt text.
- Changing the `day_dreaming` product-discovery prompt text.
- Adding scheduled or recurring operator tasks.
- Allowing operator runs to execute concurrently with issue-backed runs unless the existing runtime concurrency model already permits it.
- Creating fake Linear issues for operator runs.
- Reworking the entire issue-backed runner if a small shared adapter can safely reuse it.

## Acceptance Criteria

- Clicking `Take a nap` when idle creates a run that progresses beyond `operator_task.started`.
- Clicking `Day dreaming` when idle creates a run that progresses beyond `operator_task.started`.
- Dashboard `Running sessions` shows a non-empty `workspace_path` once workspace preparation succeeds.
- Dashboard `Running sessions` shows a Codex session id once Codex starts.
- Session history includes meaningful phases such as workspace preparation, Codex session start, agent messages, tool calls, token updates, completion, and failure.
- Token counters move from `0` when Codex reports usage.
- Run detail for an operator run answers what the agent did, what commands/tools ran, what failed, and what final summary was produced.
- Force stop terminates an active operator run process and persists `stopped`.
- A failed workspace setup or Codex startup marks the run `failed` instead of leaving it `running`.
- `runtime_busy?/1` cannot be held forever by an operator entry with no process and no Codex session.
- Queued operator tasks start after the current real run completes, fails, or stops.
- Existing issue-backed dispatch, workspace setup, Codex updates, run detail, and force stop behavior continue to work.

## Test Cases

- Orchestrator unit/integration test:
  - request `:nap` while idle;
  - assert a monitored process/ref is stored in `state.running`;
  - assert the run is not represented only by a synthetic entry.
- Workspace test:
  - fake workspace preparation succeeds;
  - assert operator run records the workspace path and emits a workspace-created session event.
- Codex session test:
  - fake Codex app server starts;
  - assert operator run records `session_id`;
  - assert Codex updates update `last_codex_event`, session history, and token counters.
- Completion test:
  - fake operator Codex turn completes;
  - assert persisted run status is `completed`;
  - assert the running entry is removed;
  - assert `operator_tasks[kind].status` returns to an idle/completed state that allows another request.
- Failure test:
  - fake workspace setup fails;
  - assert run status is `failed`;
  - assert `failure_reason` is persisted and visible in run detail;
  - assert the runtime is no longer busy.
- Force stop test:
  - active operator run has a real pid/ref;
  - force stop cancels the process;
  - assert persisted run status is `stopped`;
  - assert no Linear rollback is attempted.
- Queue test:
  - request `Take a nap` while an issue-backed run is active;
  - assert the operator task is queued;
  - finish the issue-backed run;
  - assert the operator task starts as a real run, not a synthetic row.
- Stale-entry recovery test:
  - simulate a running operator entry without live pid/ref/session after restart or crash;
  - assert reconciliation marks it failed/stopped with a diagnostic event rather than leaving runtime busy.
- Regression test:
  - issue-backed implementation run still prepares workspace, starts Codex, records session history, and completes as before.

## Implementation Notes

- Prefer a small operator-run adapter over duplicating the full issue-backed runner. The operator context differs mainly by:
  - no Linear issue id;
  - no Linear state transition;
  - profile is selected directly from operator kind;
  - final output is issue creation or discovery results, depending on profile/tool policy.
- A good target shape is an internal context struct such as:
  - `run_id`;
  - `kind`;
  - `profile`;
  - `label`;
  - `issue: nil`;
  - `workspace_scope`;
  - `prompt_context`;
  - `allowed_tools`.
- Audit existing issue-backed execution boundaries before adding new orchestration code:
  - workspace preparation facade;
  - profile prompt builder;
  - Codex app server/session handling;
  - Codex update persistence;
  - run completion/failure persistence;
  - force-stop process tracking.
- The Dashboard should remain a consumer of running state, not the source of truth.
- Do not count a row as active execution unless it has a live process/ref or a live/recoverable Codex session.
- If an operator run fails before Codex starts, still create readable session history:
  - request accepted;
  - workspace preparation started;
  - workspace preparation failed, or Codex startup failed;
  - final failed state.
- Avoid storing prompt text only in transient state. The run detail should expose enough evidence to diagnose what profile/prompt class was used without dumping secrets.

## Verification

- `mise exec -- mix test test/symphony_elixir/orchestrator_operator_tasks_test.exs test/symphony_elixir/workspace_disk_guard_test.exs`
  - Result: 8 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/orchestrator_operator_tasks_test.exs test/symphony_elixir/workspace_disk_guard_test.exs`
  - Result: 57 tests, 0 failures.
- `mise exec -- mix test --cover`
  - Result: 623 tests, 0 failures, 2 skipped, total coverage 86.01%.
- `mise exec -- mix exec_plans.check`
  - Result: passed.

## Completion Deviations

- Operator completion/failure tests use an injected fake `AgentRunner` module at the orchestrator boundary. This keeps UI/runtime orchestration tests decoupled from real Codex startup and real workspace cloning while still asserting real `pid`/`ref`, runtime update, Codex update, completion, failure, and stale-entry behavior.
- While wiring the operator path through the workspace disk guard, the guard was made struct-safe for `Config.Schema` settings instead of relying on the orchestrator rescue path. This is an adjacent correctness fix discovered by the new operator start path.

## Dependencies

- Completed plan 184 for the original `Take a nap` control.
- Completed plan 185 for the `nap` profile contract.
- Completed plan 186 for restricted Linear issue creation during nap.
- Completed plan 187 for nap audit result semantics.
- Completed plan 188 for the `Day dreaming` control and prompt intent.
- Completed plan 193 for no-issue first-class run display and persistence shape.
- Completed plan 192 for workspace disk-space guard policy.
- Completed plan 202 for workspace lifecycle facade thinning.
- Completed plan 164 for agent runner sequencing boundaries.

## Handoff Notes

Treat this as a runtime correctness bug. The current UI is accurately exposing that the operator task has no executor: `session n/a`, token total `0`, no workspace path, and only `operator_task.started`.

The implementation should not add another Dashboard workaround. The durable fix is to ensure `start_operator_task/2` either starts real execution or fails fast with a persisted diagnostic. A `running` operator row that has no process, no workspace, and no Codex session is misleading and can block the scheduler indefinitely.
