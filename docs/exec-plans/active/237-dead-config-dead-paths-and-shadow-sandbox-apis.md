# 237 Dead config, dead paths, and shadow sandbox APIs

## Goal

Delete confirmed-dead config keys, unreachable code paths, and test-only shadow APIs; align declared types with reality.

## Status

Active.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Dead code [2][3][4][5][6] + bad smell [5]: auto_cleanup (schema.ex:94-106), TrackerConfig (persistence/tracker_config.ex), record_agent_turn (persistence.ex:129-150), bare :tick (orchestrator.ex:123-155,2151-2164), sandbox shadow APIs (schema.ex:405-430, config.ex:135-144, app_server.ex:387-395, codex_runtime_settings type, config.ex:24-29).

Several config/schema/API surfaces exist with no runtime consumer: `workspace.auto_cleanup` (savable, never read — users toggle it with zero effect), `TrackerConfig` (read-only legacy store; `changeset/2` has no production caller; runtime tracker config comes from WorkflowVersion), `record_agent_turn/1` (no callers; turn data is written as generic codex.update events), the bare `handle_info(:tick, state)` clause (only tests send it; production always sends `{:tick, tick_token}`), and a sandbox-policy shadow API set (`resolve_turn_sandbox_policy/2`, `codex_turn_sandbox_policy/1`, `codex_runtime_settings/2`) used only by tests while AppServer calls the real `resolve_runtime_turn_sandbox_policy/3`. `codex_runtime_settings`'s @type also declares fields its return value never has.

## Scope

- Delete `workspace.auto_cleanup` from schema/form/UI (or implement it — default: delete, since cleanup policy already exists in WorkspaceCleanupPolicy; record the decision).
- Delete `TrackerConfig` schema + list API + raw admin panel (runtime config lives in WorkflowVersion).
- Delete `record_agent_turn/1` + AgentTurn-specific read path IF events cover turn visibility (verify run-detail UI still works); otherwise wire the write (record decision in Deviations).
- Delete the bare `:tick` clause; update tests to use the token form.
- Pick ONE sandbox-policy entry (keep `Schema.resolve_runtime_turn_sandbox_policy/3` as AppServer already uses it); delete `resolve_turn_sandbox_policy/2`, `codex_turn_sandbox_policy/1`, `codex_runtime_settings/2` and their isolated tests; fix the `codex_runtime_settings` @type or drop it.
- Grep for other `Map.get ... || ...` dead-config reads in the touched modules.

## Out of Scope

- R5/O4 (schema validator dedup + tracker adapter simplification) — deferred follow-up candidates from the same report.

## Acceptance Criteria

- `grep auto_cleanup` -> zero references outside git history.
- `grep record_agent_turn` -> zero references.
- `grep codex_turn_sandbox_policy` / `resolve_turn_sandbox_policy` -> zero references (except removed tests).
- Run-detail UI still shows turns via events (verified).
- 664 tests green after deletions.

## Test Cases

- Existing tests for deleted surfaces are removed with them; remaining suites green.
- Run-detail admin page smoke test.

## Implementation Notes

Linus: if nothing breaks when you delete it, it wasn't earning its place — but verify reachability first for every candidate (the report already traced callers).

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
