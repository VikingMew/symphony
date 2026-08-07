# 127 Orchestrator Codex Update Boundary

## Goal

Extract Codex update persistence, session-history shaping, and token/rate-limit extraction out of `SymphonyElixir.Orchestrator` into a focused boundary that can be tested without the orchestrator process.

## Status

Completed.

## Background

`Orchestrator` still owns several Codex update responsibilities that are not core scheduling:

- streaming agent message detection and coalescing;
- session-history event construction;
- persisted `codex.update` payload shaping;
- history metadata sanitization;
- token usage extraction;
- rate-limit extraction;
- low-level mixed atom/string payload traversal.

Active plan 118 focuses on fixing the actual run-detail signal. This plan is the structural follow-up: after that behavior is understood, the parsing/persistence boundary should not remain buried inside the 2500+ line orchestrator.

## Scope

- Introduce a small module for Codex update event normalization and history/persistence payload construction.
- Move token usage and rate-limit extraction into that module or a sibling module with a narrow API.
- Preserve existing event payload shapes unless plan 118 intentionally changes them.
- Keep orchestrator responsible for when to persist/send updates, not how to parse every update.
- Add direct unit tests for the extracted parser/normalizer using realistic Codex update shapes.

## Out of Scope

- Implementing plan 118's behavior changes.
- Rewriting the orchestrator process model.
- Changing retry, dispatch, lifecycle, or Linear state transition behavior.
- Changing `StatusDashboard` presentation.

## Acceptance Criteria

- `Orchestrator` no longer directly owns Codex update parsing, token extraction, or rate-limit extraction.
- The extracted module has focused tests for streaming fragments, normal notifications, tool/command updates, token usage, and rate limits.
- Existing run detail/session history behavior remains compatible with current tests.
- Plan 118 can rely on the extracted boundary or hand off to it after its behavior fix lands.

## Test Cases

- Codex update with payload-only useful content produces a bounded persisted payload.
- Streaming agent message fragments coalesce with the same key and remain separate with different keys.
- Absolute token usage paths are preferred over per-turn usage paths.
- Rate-limit payloads are found in direct and nested shapes.
- Existing `orchestrator_status_test`, `run_history_test`, and `web_fake_persistence_test` remain green.

## Implementation Notes

Do not create a generic "CodexUpdateUtils" dumping ground. The module should own one contract: normalize Codex app-server updates into the event/history data Symphony persists and displays.

Prefer string-keyed external payloads at the boundary. Use `SymphonyElixir.Payload` for mixed-key reads.

## Verification

- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/dynamic_atom_usage_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_cleanup_policy_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/coverage_ignore_governance_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_startup_test.exs test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_update_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_source_preparation_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix test --cover` (418 tests, 0 failures, 2 skipped, total coverage 85.72%)
- `mise exec -- mix lint`

## Completion Deviations

None.

## Dependencies

- Active plan 118.
- Completed plan 112.
- Completed plan 116.

## Handoff Notes

Start by extracting pure functions without changing output. After the extraction is tested, behavior fixes from plan 118 should be easier to review.
