# 230 Orchestrator error honesty (fail-open gate, swallowed persistence)

## Goal

Make orchestrator error handling explicit: rate-limit gate must not silently fail open, and persistence failures must not be swallowed as success.

## Status

Active.

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
