# 234 Type the orchestrator running state; single listening source

## Goal

Replace string-discriminated running maps with typed structs and make `listening_mode` the single source of truth.

## Status

Active.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Bad smell [2] (high) + redundancy [4] (medium): orchestrator.ex:45-65,1075-1101,1594-1631,1819-1858,1922-1957,2218-2229.

`state.running` mixes issue-run and operator-run entries as untyped maps discriminated by a `kind` string (with atom/string compatibility branches and is_map/Map.get special-casing). `runtime_entry_active?/1` treats ordinary entries as active unconditionally while operator entries check pid/session. Separately, listening state exists as BOTH `listening?` boolean and `listening_mode` enum, written together everywhere but able to contradict; compatibility shims mask the contradiction.

## Scope

- Introduce `RunningIssue` and `RunningOperator` structs (or two clearly separated maps) in the running state; pattern-match instead of string discrimination.
- Remove the atom/string kind compatibility layer once structs carry the kind.
- Delete `listening?` from state; derive boolean at API boundaries from `listening_mode`.
- Update all writers/readers (orchestrator, status surfaces, tests).

## Out of Scope

- Splitting the orchestrator module itself — future candidate, not in this batch; keep this plan focused on state typing.

## Acceptance Criteria

- No `Map.get(entry, :kind)` string discrimination remains in orchestrator running-state handling.
- Tests cannot construct contradictory listening state (single field).
- 664 tests green.

## Test Cases

- Existing orchestrator tests (they cover both run kinds).
- New: pattern-match-based helpers compile; `runtime_entry_active?` behaves identically.
- Status/API tests for listening boolean derived from mode.

## Implementation Notes

This is the highest-risk refactor (orchestrator is stateful/concurrency-sensitive per AGENTS.md). Keep semantics identical; the struct extraction is mechanical once the map shapes are pinned.

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
