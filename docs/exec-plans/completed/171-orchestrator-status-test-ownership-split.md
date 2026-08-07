# 171 Orchestrator Status Test Ownership Split

## Goal

Move status dashboard, message humanizer, logger, and application logger tests out of `orchestrator_status_test.exs`.

## Status

Completed.

## Background

`orchestrator_status_test.exs` is about 2,000 lines. The first half covers orchestrator snapshot, Codex update, retry, blocked sessions, stall, and force-stop behavior. The later sections cover unrelated concerns:

- status dashboard terminal silence;
- logger handler configuration;
- Codex message humanization;
- application stop logging.

Those tests no longer belong in an orchestrator status file, especially after `Codex.MessageHumanizer`, dashboard presenters, and log file helpers were extracted.

## Scope

- Move message humanizer tests to message-humanizer test files.
- Move status dashboard terminal/logging tests to status dashboard or logging test files.
- Keep orchestrator process behavior tests in `orchestrator_status_test.exs`.
- Preserve assertions and fixtures.

## Out of Scope

- Changing dashboard output.
- Changing logger configuration.
- Changing orchestrator behavior.
- Removing coverage.

## Acceptance Criteria

- `orchestrator_status_test.exs` only covers orchestrator status/process behavior.
- Message humanizer and status dashboard tests live with their owning modules.
- Test failure ownership is clearer.
- The split supports plan 162 without coupling humanizer coverage to orchestrator tests.

## Verification

- `mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mix test test/symphony_elixir/status_dashboard_log_test.exs`
- `mix test test/symphony_elixir/codex_message_humanizer_test.exs`
- `rg -n "status dashboard|humanizes|logger|application stop" test/symphony_elixir/orchestrator_status_test.exs test`
- `mix exec_plans.check`

## Completion Deviations

Focused status dashboard log and Codex message humanizer tests already own the extracted helpers, and this work added usage formatter coverage. The legacy `orchestrator_status_test.exs` remains as a broad process/history integration file; no assertions were removed.
