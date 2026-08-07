# 217 Multi-Project Orchestrator Dispatch

## Goal

Make the single orchestrator dispatch loop project-aware: every poll cycle iterates the enabled
projects' loaded workflows (from plan 216's `WorkflowStore.list_enabled/0`), validates and fetches
each project's candidate issues against its own Linear project slug, dispatches under that
project's workflow policy, and binds persisted runs/issues to the originating `project_id`.

## Status

Active.

## Background

Plan 216 made `WorkflowStore` cache one loaded workflow per enabled project. The orchestrator
still calls the unparameterized `Config.validate!()`, `Tracker.fetch_candidate_issues()`, and
`persistence().active_workflow_version()` paths, all of which resolve to the default project's
workflow. This plan threads a per-project workflow context through the dispatch loop and into
agent child processes so every stage (validation, fetch, dispatch, workspace, prompt, Codex)
uses the originating project's configuration.

## Scope

- Config context override:
  - `SymphonyElixir.Config` reads an optional process-dictionary workflow override before falling
    back to `Workflow.current()` in `settings/0`, `settings!/0`, `validate!/0`, and
    `workflow_prompt/0`.
  - Add `with_workflow_context(workflow, fun)` helper that sets/restores the override.
- Orchestrator dispatch loop:
  - `maybe_dispatch/1` iterates `WorkflowStore.list_enabled()`; each workflow is validated and
    dispatched inside `with_workflow_context/2`.
  - `choose_issues/2` and the dispatch chain (`dispatch_issue`, `dispatch_issue_centrally`,
    `enqueue_issue_for_worker`, `spawn_issue_on_worker_host`) carry the workflow; the agent
    child process sets the context from the captured workflow before running.
  - `persist_run_started`, `persist_worker_task_queued`, and `persist_operator_run_started` use
    the current workflow's `project_id` / `workflow_version_id` instead of the unparameterized
    `active_workflow_version()`.
  - Per-project concurrency: a project contributes only when its own
    `agent.max_concurrent_agents` budget has capacity; the existing global running map remains
    the hard bound.
- Per-project config errors: validation failures for one project log once and do not prevent
  other projects from dispatching.
- Docs riding with this plan: root `README.md` observability/filtering claims where they mention
  a single project, `documentation_alignment.md` Linear-integration and observability rows.

## Out of Scope

- UI project filtering (plan 218) and Settings switching (plan 219).
- Changing Codex/Linear/worker protocol semantics.
- Per-project orchestrator processes (decision: single orchestrator).

## Acceptance Criteria

- With two enabled projects, one poll cycle fetches and dispatches eligible issues for both.
- Each project's runs/issues record the originating `project_id` and `workflow_version_id`.
- A project with a missing repository URL logs its own config error while the other project
  still dispatches.
- Agent child processes use the originating project's workspace root, hooks, and Codex settings
  (context override is visible inside the child).
- Single-project behavior is unchanged (regression).

## Test Cases

- Config override test:
  - `with_workflow_context/2` makes `Config.settings!()` return the override workflow and
    restores the previous value after.
- Dispatch iteration test:
  - mock Tracker to return issues per Linear project slug; assert both projects dispatch with
    their own workflow policy.
- Persistence binding test:
  - run started inside project B's context records `project_id` = B's id.
- Per-project validation isolation test:
  - one project with missing repository URL, one valid; assert the valid one dispatches and the
    invalid one logs a config error.
- Child-process context test:
  - the agent child process sees the originating workflow's config via `Config.settings!()`.
- Regression: existing orchestrator dispatch/status/rate-limit tests pass.

## Implementation Notes

- Process-dictionary override must be set inside the `Task.Supervisor.start_child` closure
  (child processes do not inherit the dictionary).
- `with_workflow_context/2` uses `try/after` to restore the previous dictionary value.
- `choose_issues/2` filters by the current workflow's `tracker.active_states` and concurrency
  budget; keep `available_slots` global as the outer bound.
- Reuse `persistence().active_workflow_version(project)` (plan 216) for the per-project version
  in run persistence where a project record is available; otherwise derive from the current
  workflow's `workflow_version_id`.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test` (new dispatch tests + full suite regression)
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `make all` at the end of the 217-219 sequence.

## Completion Deviations

- Orchestrator processes do not listen by default; tests must call
  `GenServer.call(pid, :start_listening)` before `:run_poll_cycle` will dispatch. This is
  existing behavior, not a deviation introduced by this plan, but it surfaced while writing the
  dispatch iteration tests.
- The process-dictionary context does not flow into `Task.Supervisor.start_child` closures
  automatically; `spawn_issue_on_worker_host/5` captures the current workflow and wraps the child
  body in `Config.with_workflow_context/2`. This matches the plan's implementation note.
- Per-project concurrency relies on a new `project_id` key in running entries (set at dispatch
  time); entries created before this change have no `project_id` and count toward no project,
  which is safe.
- The "orchestrator starts with listening disabled" test is flaky under full-suite concurrency
  (passes in isolation); this predates the plan's changes and was observed in 216 as well.
- `mix format --check-formatted`, full `mix test` (653 tests, 0 failures), and
  `mix exec_plans.check` pass. `mix lint` and `make all` run at the end of the 217-219 sequence.

## Dependencies

- Plan 216 (runtime workflow store, `list_enabled/0`, per-project loaded workflows).
- Plan 215 (documentation alignment).

## Handoff Notes

The main risk is scope creep in the dispatch chain. Keep the workflow parameter flowing from
`maybe_dispatch` through `choose_issues` into `spawn_issue_on_worker_host`; do not refactor
`agent_runner`/`workspace`/`app_server` in this plan beyond what the context override already
fixes. If a child process still reads default-project settings, the override was not set inside
the child closure — check `Task.Supervisor.start_child` first.
