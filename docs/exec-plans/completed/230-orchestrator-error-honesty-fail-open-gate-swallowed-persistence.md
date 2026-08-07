# 230 Orchestrator error honesty (fail-open gate, swallowed persistence)

## Goal

Make orchestrator error handling explicit: rate-limit gate must not silently fail open, and persistence failures must not be swallowed as success.

## Status

Completed.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Over-protection [2] (high) + [3] (medium): orchestrator.ex:2244-2288, 2416-2465, 2506-2565.

`refresh_rate_limit_gate/1`, `rate_limit_gate_blocked?/1`, `rate_limit_gate_snapshot/1` rescue any program error to allow/false — a bug in the gate implementation silently re-enables dispatch and can start operator tasks that should be paused. Separately, core persistence paths swallow errors: agent tasks continue after `persist_run_started/3` returns nil; workspace/event write failures are converted to `:ok` with no log, producing runs that executed but left no run/event/workspace records.

## Scope

- Rate-limit gate: remove catch-all rescues; rely on `RateLimitGate.check/3`'s own functional fallbacks; on unexpected errors, log structured + choose an explicit policy (fail-closed: treat as blocked, log loudly — decision to be recorded in Deviations).
- Persistence paths in orchestrator: only handle `:repo_unavailable` as degraded; other errors get structured logs; run creation is decided as strong-consistency prerequisite (fail the task) or explicit degraded mode (recorded decision), never silent nil-continue.
- Workspace/event write failures: log + propagate or explicitly mark run failed — never silent `:ok`.

## Out of Scope

- Retry machinery redesign; worker-mode persistence flow.

## Acceptance Criteria

- Gate implementation error => gate reports blocked/error state with log, NOT allow.
- Run-start persistence failure => task fails loudly with log (or explicit degraded-mode record), not silent continue.
- No `rescue`-based silent success paths remain in the touched orchestrator functions.

## Test Cases

- Stub gate raising: assert dispatch blocked + error logged.
- Stub persist_run_started failing: assert task marked failed (or degraded recorded).
- Existing orchestrator/core tests pass (664 baseline).

## Implementation Notes

Carmack: minimize what can go wrong — the gate already has typed fallbacks; the rescues exist to hide bugs. Remove the hiding.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 35 [R] + 2 [D], no new findings)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 676 tests, 0 failures, 2 skipped (baseline 664 → +12 new: 2 in rate_limit_gate_test.exs, 10 in core_test.exs)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (orchestrator.ex, rate_limit_gate_test.exs, core_test.exs)

## Completion Deviations

- Rate-limit gate: chose fail-closed policy — `check_rate_limit_gate/1` rescues evaluation errors into
  `{:block, %{status: :blocked, reason: :evaluation_error, error: ...}}` with a structured error log;
  `rate_limit_gate_message/1` renders the new blocked state.
- Run-start persistence failure: issue dispatch is skipped and the issue is scheduled for retry
  (`skip_dispatch_for_persistence/4`) with the reason in the retry error — never silent nil-continue;
  operator tasks are marked `:failed` with the persistence reason in `failure_reason`.
- Spawn-failure path now closes the run record: if the agent task fails to spawn after the run was
  persisted, `persist_run_finished/3` records the run as `failed` (previously no run record existed).
- Poll-path issue upsert (`persist_polled_issue/2`) treats `:repo_unavailable` as degraded/continue;
  any other error propagates (`:erlang.error`), surfacing as a visible failure instead of silent `:ok`.
- CoreTest gains two new integration tests (gate-block dispatch + run-start persistence failure) that
  terminate/restart the supervised Orchestrator; the existing baseline suite remains green.

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
