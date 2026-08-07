# 229 WorkflowStore error honesty (no fake setup-required)

## Goal

Stop disguising database faults as 'no workflow configured'; preserve last-known-good runtime config.

## Status

Completed.

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

Executed by Codex CLI (0.147.0, `--sandbox workspace-write`) and independently verified
by the reviewer:

- `persistence/workflow_store.ex`: all DB-touching functions wrapped in a `query/2`
  guard that logs structured errors and `reraise`s (stack preserved) — no more blanket
  `rescue -> nil/[]/:repo_unavailable`. Explicit `Persistence.repo_available?()` checks
  keep the `:repo_unavailable` degraded path (nil/[]/error) as the ONLY swallowed case.
- `workflow_store.ex`: `load_state/0` returns `{:ok, state} | :setup_required |
  {:error, reason}`; `reload_state` retains last-known-good on error (log
  `action=retain_last_known_good`); `load_initial_state` degrades to an error-state
  only for `:repo_unavailable` (log `action=use_error_state`), raises for other errors.
- Tests: `workflow_store_test.exs` (new) + `persistence/workflow_store_test.exs` —
  covers empty-DB setup-required (no regression), repo-unavailable degraded start,
  and reload-failure preserving a previously loaded workflow.
- Gates (reviewer, outside sandbox): `mix test` -> **673 tests, 0 failures, 2 skipped**
  (669 + 4 new); `mix format --check-formatted` pass (after formatting); `mix credo
  --strict` 0 [F] (35 [R] + 2 [D] unchanged); `mix compile --warnings-as-errors` pass;
  `mix specs.check` pass; `mix exec_plans.check` pass.
- Diff scope: 2 whitelisted lib files + 2 test files (1 modified, 1 new).

## Completion Deviations

- Codex left 3 `Logger.error` multi-line calls unformatted and introduced a credo [F]
  (`default_project` nested too deep through the `query/2` wrapper). Reviewer ran
  `mix format` and extracted `default_project!/0` private helper — credo back to 0 [F].
- Error classification rule (recorded decision): `repo_unavailable` = explicit
  `Persistence.repo_available?()` guard (the persistence provider's own signal);
  everything else = log + propagate/raise. No catch-all swallows remain in the touched
  query paths.

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
