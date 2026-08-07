# 216 Multi-Project Runtime Workflow Store

## Goal

Make the runtime workflow source multi-project: `SymphonyElixir.WorkflowStore` caches the active
loaded workflow for every enabled project (keyed by project id) while keeping single-workflow
compatibility for existing callers. Add per-project workspace hook fields to the `projects`
persistence record and settings UI, and overlay them onto the loaded workflow config.

## Status

Completed.

## Background

The data layer already stores multiple projects and per-project workflow versions, but
`SymphonyElixir.WorkflowStore` caches only the default project's workflow
(`active_workflow_version/0`), and workspace hooks are global in the workflow config. Plan 215
inventories the design/documentation changes; this plan lands the runtime store half.

## Scope

- `SymphonyElixir.WorkflowStore`:
  - Cache `%{project_id => loaded_workflow}` for every enabled project with an active workflow
    version, plus `default_project_id`.
  - New API: `list_enabled/0` and `for_project/1`.
  - Keep `current/0` / `current_with_source/0` returning the default project's workflow (or the
    first enabled project's when the default has none) for compatibility.
  - `source` payload gains `workflow_versions` map (project_id => version_id) while keeping
    `type: :database` / `:setup_required`.
- Per-project hooks:
  - Add `after_create_hook`, `before_run_hook`, `after_run_hook`, `before_remove_hook` to the
    `projects` table (migration), `SymphonyElixir.Persistence.Project` schema/changeset, and
    project settings form (`ProjectSettings` attrs/compare fields + admin LiveView form fields).
  - `apply_project_runtime_settings/2` overlays non-blank project hook fields onto
    `config["hooks"]`; unset fields leave workflow-level hooks intact.
- Fake persistence (`test/support/fake_persistence.exs`):
  - `active_workflow_version/1` (per project, newest version).
  - `import_workflow/3` appends versions and uses per-project version ids.
  - Project attrs/hook overlay support.
- Tests for multi-project loading, default selection, hooks overlay, disabled exclusion.
- Docs riding with this plan: SPEC.md 5.3/6.4/9.4 project-model claims, ARCHITECTURE.md runtime
  flow, CODE_STRUCTURE.md WorkflowStore row, elixir/README.md configure step,
  workspace_source_layout.zh-CN.md isolation note, persistence_and_auth.md.

## Out of Scope

- Orchestrator dispatch over multiple projects (plan 217).
- UI project filtering (plan 218) and settings switching (plan 219).
- Per-project concurrency policy changes.

## Acceptance Criteria

- With two enabled projects each having an active workflow version, `list_enabled/0` returns
  both and `for_project/1` returns the right one per project id.
- `current/0` returns the default project's workflow; setup-required state still surfaces when no
  enabled project has an active workflow version.
- A project with `before_run_hook` set exposes that hook in its loaded config; projects without
  it keep the workflow-level hook.
- Disabled projects are excluded from the runtime cache.
- Single-project behavior is unchanged for callers of `current/0` (regression).

## Test Cases

- WorkflowStore multi-project test:
  - seed two enabled projects with distinct active versions;
  - assert `list_enabled/0` returns both, `for_project/1` returns each project's workflow, and
    `current/0` returns the default project's workflow.
- `for_project/1` unknown id returns `{:error, :not_found}`.
- Disabled project excluded from `list_enabled/0`.
- Project hook overlay: set `before_run_hook` on a project, assert loaded config hooks carry it.
- Workflow-level hook preserved when project hook unset.
- Fake persistence: `active_workflow_version/1` returns newest per-project version.
- Regression: existing workflow-store, prompt-builder, and settings tests pass.

## Implementation Notes

- `WorkflowStore` state becomes `%State{workflows: map, default_project_id: id | nil, source: map}`.
  `state_payload/1` materializes the compatibility `workflow` (setup-required workflow when the
  map is empty) so `current/0` keeps its contract.
- Load only enabled projects; a project without an active version contributes nothing; if no
  project contributes, the store is `:setup_required`.
- Hook overlay lives in `SymphonyElixir.Persistence.WorkflowStore.apply_project_hooks/2` and is
  mirrored in fake persistence so UI tests observe the same behavior.
- Keep `@spec` on all new public functions per AGENTS.md.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test` (new multi-project tests + full suite regression)
- `mise exec -- mix lint`
- `mise exec -- mix specs.check`
- `mise exec -- mix exec_plans.check`
- `make all`

- Closed with plan 219 (multi-project line complete). Final gate state after plans 221-224: 664 tests / 0 failures, format + specs pass, credo 0 `[F]`, dialyzer 0 warnings, exec_plans.check pass.

## Completion Deviations

- `WorkflowStore.source` payload uses a `workflow_versions` map (project_id => version_id)
  instead of the previous single `workflow_version_id` key, as specified. No behavioral
  deviation.
- Fake persistence needed two fidelity fixes beyond the plan text:
  - `active_workflow_version/1` must return the **newest** per-project version (real persistence
    selects `order_by: [desc: version]`), so the fake searches from the tail of the appended
    versions list.
  - Fake "active" semantics live in the `active_workflow_version` slot, not the version's own
    `:active` flag, so the per-project lookup must not filter on `:active`.
- Elixir operator-precedence pitfall hit during implementation: `state.workflow_versions || []`
  piped into `Enum.reverse/1` evaluates as `state.workflow_versions || ([] |> Enum.reverse())`
  and returns the whole list when non-empty. Parenthesize `(state.workflow_versions || [])`.
- `mix specs.check` reports 5 missing `@spec` declarations in modules unrelated to this plan
  (`codex/message_humanizer/methods.ex`, `codex/rate_limit_gate.ex`, `linear/issue_normalizer.ex`,
  `orchestrator/dispatch_policy.ex`, and one more). These are pre-existing and not introduced by
  this plan; they will be addressed separately.
- `mix format --check-formatted`, full `mix test` (648 tests, 0 failures), and
  `mix exec_plans.check` pass. `mix lint` and `make all` were not run in this plan's verification
  because a separate task (217) follows immediately; they run at the end of the 217-219 sequence.

## Dependencies

- Plan 215 (design/documentation alignment) defines the doc sweep this plan rides with.

## Handoff Notes

The tricky part is fake persistence fidelity: real persistence selects the newest active workflow
version per project, and fake tests seed versions through several paths
(`put_workflow_versions/2`, `import_workflow/3`). The per-project lookup must mirror "newest
matching version" semantics or a batch of existing tests fail. Also watch Elixir operator
precedence when piping from `||` defaults — parenthesize `(list || [])`.
