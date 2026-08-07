# 229 WorkflowStore error honesty (no fake setup-required)

## Goal

Stop disguising database faults as 'no workflow configured'; preserve last-known-good runtime config.

## Status

Active.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Over-protection [1] (high): workflow_store.ex:142-169, persistence/workflow_store.ex:81-94,140-147.

`load_database_workflows/0` rescues ALL exceptions and returns `:setup_required`; the lower active/list queries also convert exceptions to `nil`/`[]`. SQLite corruption, query bugs, or connection failures therefore clear the runtime workflow and show the user a misleading 'open /settings/workflow to create one' path. The spec and AGENTS.md ('explicit errors over silent tolerance') demand typed, visible failures.

## Scope

- `lib/symphony_elixir/workflow_store.ex` and `lib/symphony_elixir/persistence/workflow_store.ex`: map ONLY the explicit `:repo_unavailable` (and clearly expected transient states) to recoverable/empty; all other errors are logged (structured) and propagated.
- GenServer keeps last-known-good workflow when a reload fails (cache the last loaded workflows; on error, log + retain prior state instead of clearing).
- Status/UI: when DB is genuinely unavailable, surface a distinct error state rather than setup-required.

## Out of Scope

- Retry/backoff redesign; repo-unavailable degradation policy beyond preserving prior state.

## Acceptance Criteria

- A simulated DB error (stubbed persistence) produces a logged error + retained last-known-good, NOT `:setup_required`.
- A truly empty DB still starts setup-required (no regression).
- `:repo_unavailable` paths still degrade gracefully (tests cover).

## Test Cases

- Fake persistence raising on load: assert error logged and prior workflows retained.
- Empty DB: setup-required still returned.
- Existing workflow_store/orchestrator startup tests pass.

## Implementation Notes

Distinguish 'never configured' (setup_required, valid) from 'could not read' (error, keep old state). Add a dedicated error reason so callers can distinguish.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (664 baseline, 0 failures, 2 skipped; known flaky:
  OrchestratorStatusTest `:sys.get_state` timeout, HookRunnerTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

## Dependencies

None.

## Handoff Notes

Executed by Codex CLI in a clean worktree (`--sandbox workspace-write`). Prompt must
carry: file whitelist, environment-noise rules (Mix.PubSub/port/socket errors in sandbox
are noise — continue), forbid touching docs/exec-plans and design docs, forbid adding
`.dialyzer_ignore.exs` entries, forbid custom build environments (`_build/codex_*`),
report format (Completed / Validation / Deviations / Blockers). Reviewer runs the full
gate sequence outside the sandbox, reviews the diff for behavior equivalence, archives
this plan, and commits.
