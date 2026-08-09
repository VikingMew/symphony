# 251 Operator tasks (nap / day_dreaming) select their project explicitly

## Goal

Operator tasks (nap, day_dreaming) currently run without a project dimension: the synthetic
issue built by `AgentRunner.run_operator/4` carries no project, so the workspace checkout falls
back to the default project's workflow (and after plan 250 removes the auto-created default,
falls back to the first enabled project). The dashboard cannot select which project a nap should
audit — there is no project selector because the request API never accepted one.

This plan threads an explicit `project_id` (and project slug for the dashboard dropdown) through
the operator-task request chain: dashboard button → orchestrator request → operator task state →
synthetic issue → workspace preparation. When no project is specified, the operator task fails
with a visible error instead of silently running against an arbitrary project.

## Status

Active.

## Background

- `Orchestrator.request_nap/0` / `request_day_dreaming/0` (orchestrator.ex:1577-1591) accept no
  project argument; `handle_call({:request_operator_task, kind}, ...)` (orchestrator.ex:1822-1827)
  forwards only the kind atom.
- `request_operator_task(state, kind)` (orchestrator.ex:1846) builds the task via
  `new_operator_task(kind)` (orchestrator.ex:1895) — the task map has no `project_id` field.
- `AgentRunner.run_operator(kind, run_id, recipient, opts)` (agent_runner.ex:53-82) constructs a
  synthetic `%Issue{}` (agent_runner.ex:59-67) with `labels: ["operator", profile]` and no
  project; `Workspace.create_for_issue/3` then prepares the workspace, and the source strategy
  resolves repository configuration from the current (default) workflow because no project
  context exists.
- `DashboardLive.handle_event("request_nap", _params, socket)` (dashboard_live.ex:93) ignores
  params entirely — no project selection UI exists.
- After plan 250, `default_project()` no longer auto-creates; the no-arg resolution chain is
  default record → first enabled project → nil. Operator tasks must not silently depend on that
  chain; they should state their project explicitly.
- Projects are listed via `Persistence.list_projects/0`; each project has id, name, slug,
  enabled, repository_url, default_branch, source_strategy. The dashboard shell already loads
  projects for other surfaces (admin settings).

## Scope

- `Orchestrator.request_nap/1`, `request_day_dreaming/1` accept an optional `project_id`; the
  `/0` arities keep backward compatibility (no project → error task at runtime, not silent
  default).
- `operator task` state map gains a `project_id` field (nil allowed but rejected at start time
  with a visible failure_reason).
- `new_operator_task(kind, project_id)` carries the project; `start_operator_task` and
  `spawn_operator_task` pass it to `AgentRunner.run_operator(kind, run_id, recipient,
  project_id: project_id)`.
- `AgentRunner.run_operator/4` accepts `project_id` in opts, attaches it to the synthetic issue
  (`%Issue{project_id: project_id}` or the project struct as needed by workspace), so
  `Workspace.create_for_issue/3` resolves the correct repository instead of the default.
- Dashboard: nap / day dreaming controls gain a project selector (dropdown of enabled projects)
  and pass `project_id` in the event params; when the selected project has no active workflow,
  surface an error flash instead of queueing.
- Reject at request time when `project_id` is absent and more than one enabled project exists
  (explicit error), or when the project_id is unknown/disabled.
- Update tests: orchestrator request_nap with/without project; operator task state carries
  project_id; agent_runner synthetic issue carries project; dashboard event passes params.

## Out of Scope

- Changing the operator profile prompt content (nap / day_dreaming standards stay as-is).
- Multi-project operator tasks (one task auditing several projects at once).
- Selecting a Linear project (issue.project) — this is the symphony workspace/repository project,
  which is what determines the checked-out source.

## Acceptance Criteria

- `Orchestrator.request_nap(project_id)` queues/starts a nap for exactly that project's workflow;
  workspace checkout uses that project's repository_url/source_strategy.
- `request_nap()` with no project and ≥2 enabled projects returns an error task with a visible
  `failure_reason` ("project required") — no silent default.
- `request_nap()` with no project and exactly 1 enabled project still works (that project is
  unambiguous) — preserves single-project ergonomics.
- Unknown/disabled project_id → error task with visible reason.
- Dashboard nap/day dreaming controls include a project dropdown; selecting a project with no
  active workflow shows an error flash, no queue.
- Operator task state payload (dashboard / api state) includes `project_id` (or project slug) so
  the UI can show which project the nap is auditing.
- `mix exec_plans.check` passes; `make all` passes.

## Test Cases

- orchestrator_test: `request_nap(project_id)` with an enabled project → task status
  running/queued and `project_id` set; with nil and 2 projects → task status failed with
  `project required` reason; with nil and 1 project → starts.
- orchestrator_test: unknown project_id → failed with reason; disabled project → failed.
- agent_runner_test: `run_operator(:nap, run_id, nil, project_id: pid)` synthetic issue carries
  the project; workspace preparation receives the project (assert via test seam or issue
  fields).
- dashboard_live_test: `request_nap` event with `%{"project_id" => id}` passes it to the
  orchestrator; project with no active workflow → error flash.

## Implementation Notes

- Keep `/0` arities delegating to a resolver: `resolve_operator_project/1` returns
  `{:ok, project}` (single enabled project), `{:error, :project_required}` (none or ambiguous),
  or `{:error, :unknown_project}`. This keeps the explicit-error behavior in one place and
  matches the plan-250 resolution-chain style.
- The synthetic issue needs whatever project shape `Workspace`/`SourcePreparation` consume
  today (likely `%Project{}` or a map with repository_url/default_branch/source_strategy).
  Inspect `Workspace.run_project_bootstrap` / `prepare_worktree_source` before coding to thread
  the exact struct.
- Do not change operator prompt templates; only the request/state/issue/project plumbing.

## Verification

- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/orchestrator_test.exs test/symphony_elixir/agent_runner_test.exs test/symphony_elixir_web/live/dashboard_live_test.exs`
- `mise exec -- mix specs.check`
- `mise exec -- mix exec_plans.check`
- `make all`

## Completion Deviations

(To be filled on completion.)
