# 175 Production Test Only API Removal

## Goal

Remove public `_for_test` and `format_*_for_test` APIs from production modules by moving tests to real public boundaries or dedicated test helpers.

## Status

Completed.

## Background

Several production modules still expose functions solely for tests:

- `SymphonyElixir.Orchestrator.reconcile_issue_states_for_test/2`
- `SymphonyElixir.Linear.Client.request_options_for_test/1`
- `SymphonyElixir.Linear.Client.fetch_issue_states_by_ids_for_test/2`
- `SymphonyElixir.StatusDashboard.format_snapshot_content_for_test/2`
- `SymphonyElixir.StatusDashboard.format_snapshot_content_for_test/3`

These were useful while extracting boundaries, but they are now a bad smell. They widen production APIs for test convenience and hide missing public boundaries.

## Scope

- Replace `_for_test` usages with tests against extracted policy/normalizer/protocol modules where available.
- For process-only behavior, use supervised integration tests rather than exposing private helpers.
- If a helper is genuinely useful outside tests, rename it as a real public API and document/spec it accordingly.
- Add a static check that rejects new `_for_test` public functions under `lib/`.

## Out of Scope

- Removing useful public APIs that are not test-only.
- Weakening integration coverage.
- Changing runtime behavior.
- Moving all tests in the same change.

## Acceptance Criteria

- No public function under `lib/` ends with `_for_test`.
- No public function under `lib/` is named `*_for_test` or `format_*_for_test`.
- Existing tests still cover orchestrator reconciliation, Linear request options/pagination, and status dashboard silence.
- Future test-only hooks live in `test/support` or in focused fake modules.

## Verification

- `rg -n "def .*_for_test|_for_test\\(" lib test`
- `mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mix test test/symphony_elixir/status_dashboard_log_test.exs`
- `mix exec_plans.check`

