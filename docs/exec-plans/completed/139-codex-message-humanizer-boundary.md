# 139 - Codex Message Humanizer Boundary

Status: Completed

## Problem

Codex message humanization is still owned by `StatusDashboard`, even though it is used outside the dashboard process and presentation shell.

Current callers include presenter, rate-limit status, event presenter, run history, Codex update handling, and orchestrator code. This creates two problems:

- A shared pure formatting concern depends on a dashboard module.
- The module that owns the helper is still part of the coverage ignore shell, so meaningful behavior is harder to count and govern.

This is redundant coupling and a bad smell: generic message normalization should not live in a process-oriented dashboard boundary.

## Goal

Extract Codex message humanization into a small counted pure module with focused tests.

The dashboard should call that module like every other consumer. `StatusDashboard` can then continue shrinking toward dashboard state orchestration only, with less behavior hidden behind coverage ignores.

## Plan

1. List every call to `StatusDashboard.humanize_codex_message/1`.
2. Create a pure module such as `SymphonyElixir.Codex.MessageHumanizer`.
3. Move message normalization logic and edge-case handling into the new module.
4. Update all callers to depend on the new module rather than `StatusDashboard`.
5. Add focused tests for nil/empty messages, structured Codex text, rate-limit messages, and already-human-readable text.
6. Leave `StatusDashboard` without a compatibility wrapper unless an incremental migration needs one; if a temporary wrapper is necessary, mark it for immediate removal in the same plan.
7. Revisit the coverage ignore list after extraction and remove `StatusDashboard` only if the remaining process shell is practical to test directly.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex/message_humanizer_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/event_presenter_test.exs test/symphony_elixir/run_history_test.exs`
  - `57 tests, 0 failures`
- `rg -n "humanize_codex_message|MessageHumanizer|StatusDashboard\\.humanize" lib test`
  - `StatusDashboard.humanize_codex_message/1` no longer exists or has callers.
  - `SymphonyElixir.Codex.MessageHumanizer` owns the pure formatter and all callers reference it directly.
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.

## Completion Deviations

None.
