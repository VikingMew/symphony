# 066 Session History Observable Details

## Goal

Make running session history entries explain what happened instead of rendering
generic event names such as `notification`.

## Status

Completed.

## Background

The dashboard currently shows long runs of entries like:

```text
Notification 2026-05-09T06:03:01Z notification
Notification 2026-05-09T06:03:08Z notification
```

This is not actionable. The runtime already receives Codex protocol payloads
that include method names, command text, tool names, token usage, approval
requests, and turn status. The status dashboard already has
`StatusDashboard.humanize_codex_message/1`, but session history detail fallback
uses the raw event atom for most events. As a result, `:notification` renders as
`notification` even when the underlying payload contains useful context.

## Scope

- Change session history detail generation so Codex events use the existing
  Codex message humanizer.
- Preserve existing labels such as `Notification`, `Tool call completed`, and
  `Turn failed`.
- Preserve special non-Codex details such as:
  - run start state;
  - workspace path;
  - Linear state transition messages.
- Ensure command, tool, turn, approval, token, and message-stream events produce
  useful detail strings.
- Add regression tests that prove a `:notification` event with a Codex payload
  renders a specific detail such as `mix test`, not `notification`.
- Keep the dashboard expanded/collapsed state behavior unchanged.

## Out of Scope

- Rebuilding old persisted/session history entries that already lost their
  detail.
- Adding a new event model or database migration.
- Changing Codex protocol handling.
- Changing persisted run/event pages beyond the session history detail text.
- Filtering or collapsing duplicate notifications. That can be a follow-up if
  the improved details still produce too much noise.

## Acceptance Criteria

- New session history entries for Codex notifications show a humanized detail
  from the payload.
- A command-start payload renders the command text in session history.
- A tool call payload renders the tool name in session history.
- A turn completion/failure payload renders turn status or failure detail.
- Non-Codex history entries keep their existing detail behavior.
- Existing dashboard session-history expansion state remains stable across
  LiveView updates.
- Focused tests pass.
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
  passes.
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs` passes.
- `mise exec -- mix lint` passes.

## Test Cases

- Orchestrator snapshot receives a `:notification` update with
  `codex/event/exec_command_begin`; session history detail is the command text.
- Orchestrator snapshot receives an `item/tool/call`; session history detail
  includes the tool name.
- Run-start history still says `Started from <state>`.
- Workspace-ready history still displays the workspace path.
- Dashboard LiveView still keeps session history expanded after an update.

## Implementation Notes

- The smallest code-level fix is in `Orchestrator.history_detail/2`.
- `append_codex_history/2` already stores `message: summarize_codex_update(update)`
  in metadata. Use that metadata with `StatusDashboard.humanize_codex_message/1`.
- Keep the humanizer as the single place that understands Codex protocol
  variants.
- If a payload cannot be humanized, fallback to the event name to preserve
  current behavior.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix test`

## Completion Deviations

None.

## Dependencies

- Existing `StatusDashboard.humanize_codex_message/1`.
- Existing session history state in the orchestrator snapshot.

## Handoff Notes

This plan intentionally does not deduplicate notification spam. It only makes
each row explain the observed condition. If the UI remains noisy, add a separate
plan for aggregation or filtering.
