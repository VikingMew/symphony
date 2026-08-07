# 234 Type the orchestrator running state; single listening source

## Goal

Replace string-discriminated running maps with typed structs and make `listening_mode` the single source of truth.

## Status

Completed.

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

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 23 [R] + 2 [D], down from 28 [R])
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 680 tests, 0 failures, 2 skipped (full suite, single run; the known
  cross-file persistence race did not trigger this run)
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (orchestrator.ex, dashboard_presenter.ex, presenter.ex,
  + 6 test files)
- acceptance-check: `grep 'Map.get(.*:kind' lib/symphony_elixir/orchestrator.ex` -> zero hits;
  all `listening?` occurrences are derived API replies or the `listening?/1` definition itself

## Completion Deviations

- `RunningIssue` / `RunningOperator` structs live inside `Orchestrator` (defstruct in the same file).
  Internal `kind` is an atom (:issue / :nap / :day_dreaming); conversion to the legacy strings
  happens only at API/log/event boundaries via the new `running_entry_kind/1` helper.
- All `listening?` State field writers/readers removed; `listening?/1` derives from
  `listening_mode` (:not_listening => false, anything else => true) and every handle_call reply /
  snapshot payload computes it from the post-mutation state. `listening_mode_string/1` and
  `listening_mode_atom/1` collapsed to simple atom<->string conversions (the old `listening?: true`
  fallback clauses are gone — no state can contradict anymore).
- `operator_running_entry?/1` deleted; every dispatch site pattern-matches `%RunningOperator{}` /
  `%RunningIssue{}` instead (worker-down handling, stalled restart, rollback, stale reconciliation,
  issue_running_ids, runtime_entry_active?).
- `InputBlocker.entry/3` receives `Map.from_struct/1` of the running entry (it expects a plain map).
- `SymphonyElixirWeb.Presenter.running_entry_kind/1` added to read the struct `kind` (fallback
  "issue"); `DashboardPresenter.listening_mode/1` normalization simplified to atom|binary -> string
  with "not_listening" fallback (the `listening?` boolean fallback was removed since snapshots no
  longer carry it).
- Test changes are mechanical: `listening?: true` -> `listening_mode: :listening_all`, running-entry
  maps -> `%Orchestrator.RunningIssue{...}` literals; no assertion semantics changed.
- 680-test baseline kept; no behavior deltas observed in any orchestrator/status/dashboard test.

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
