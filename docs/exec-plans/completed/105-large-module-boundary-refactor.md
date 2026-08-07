# 105 Large Module Boundary Refactor

## Goal

Reduce change risk in Symphony's largest runtime and UI modules by extracting stable, testable boundaries without changing user-visible behavior.

## Status

Completed.

## Background

The current implementation has several modules that have accumulated many responsibilities:

- `lib/symphony_elixir/orchestrator.ex`: 2,652 lines.
- `lib/symphony_elixir_web/live/admin_live.ex`: 2,200 lines.
- `lib/symphony_elixir/codex/app_server.ex`: 1,373 lines.
- `lib/symphony_elixir/workspace.ex`: 1,294 lines.
- Several broad test files exceed 1,600 lines.

These files are not automatically wrong, but the size now reflects real coupling: scheduling policy, persistence event shaping, UI form state, import/export, protocol framing, process launch, workspace source strategies, and cleanup behavior are mixed into a few edit hotspots. This makes reviews slow, merge conflicts common, and coverage harder to interpret.

## Scope

- Extract small modules around existing behavior, preserving public behavior and data shapes.
- Add compatibility tests around each extraction before or during the move.
- Keep changes incremental enough that each PR can be reviewed independently.
- Prefer pure or mostly pure boundaries first.

Suggested extraction order:

1. `AdminLive` form/import/history boundaries.
2. Workspace source-strategy operations.
3. Codex app-server protocol and launch-policy boundaries.
4. Orchestrator dispatch/retry/reconciliation boundaries.

## Out of Scope

- Rewriting the orchestration model.
- Changing routes, settings screens, workflow schema, or worker API semantics.
- Moving persistence storage to another backend.
- Combining this refactor with state-flow or documentation consistency fixes.

## Acceptance Criteria

- The largest modules shrink through behavior-preserving extractions.
- Extracted modules have clear names and ownership.
- Tests cover each extracted boundary directly or through an existing compatibility path.
- Existing dashboard, workflow import, workspace setup, Codex session, and orchestrator tests continue to pass.
- No operator-facing behavior changes are introduced except clearer internal organization.

## Test Cases

- `AdminLive` import tests still prove `workflow.yml` and `profiles.yml` populate the structured draft correctly.
- Settings history restore tests still prove section-scoped restores write a complete active workflow version.
- Workspace tests still prove clone/worktree setup, cleanup, symlink escape rejection, and root deletion protection.
- App-server tests still prove startup failure context, approval policy handling, env scrubbing, dynamic tool handling, and timeout behavior.
- Orchestrator status tests still prove dispatch, retries, phase events, worker-mode behavior, and session presentation.

## Implementation Notes

- Start with pure helpers and value transformations. Good candidates:
  - `SymphonyElixirWeb.Admin.WorkflowImport`
  - `SymphonyElixirWeb.Admin.WorkflowFormParams`
  - `SymphonyElixir.Workspace.SourceStrategy`
  - `SymphonyElixir.Codex.Protocol`
  - `SymphonyElixir.Codex.LaunchPolicy`
  - `SymphonyElixir.Orchestrator.Dispatch`
  - `SymphonyElixir.Orchestrator.Reconciliation`
- Keep names aligned with current local conventions; avoid introducing framework-heavy abstractions.
- Do not move code only to reduce line count. Each extraction should remove a meaningful reason to edit the parent module.
- Preserve logging fields and event payloads unless a separate plan explicitly changes them.
- When moving private helpers, add module-level tests for the new public boundary instead of testing private functions.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

Completed with focused extractions that directly supported the active bug fixes: `SymphonyElixir.RunHistory` owns persisted run session-history presentation, and `SymphonyElixir.RunLifecycle` owns terminal run persistence and stale-running reconciliation. Broader AdminLive/Workspace/AppServer decomposition remains future refactor work.

## Dependencies

- Plan 104 for the original audit finding.
- Plan 099 for test-suite layer decoupling context.
- Plan 103 if orchestrator/session-history presentation is extracted near run history work.

## Handoff Notes

Do this after the P0/P1 consistency cleanup from plan 104. Large-module refactoring is valuable, but it should not be mixed with fixing stale runtime-contract docs or the invalid bundled workflow package.
