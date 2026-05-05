# Task 027: Replace Terminal TUI With Normal Logger Output

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 004, 016, 021, 024, 026
**Created**: 2026-05-05
**Completed**: 2026-05-05

## Goal

Replace Symphony's terminal TUI/status renderer with normal application logging.

"Normal logging" means the application uses Elixir `Logger` in the same spirit as slf4j/loguru: application code emits short, human-readable messages for meaningful operational events, and the configured logger backend/formatter owns timestamp, level, metadata, and destination formatting.

This task must not replace the TUI with another custom terminal status language. In particular, it must not emit synthetic key/value status lines such as `level=... source=... entity=...`, and it must not append periodic runtime snapshots to stdout.

It is acceptable to configure a meaningful project-level `Logger` formatter if the default console output is not suitable. That formatter must remain a general-purpose logger formatter, not a Symphony status renderer: it should format ordinary `Logger` events consistently and should not require business code to build custom status-line strings.

## Background

The old terminal status display was a TUI-like live frame: it cleared the terminal, moved the cursor home, drew borders/tables, and refreshed regularly so operators could see live state at a glance.

That model does not translate to append-only output. If the same refresh loop simply appends text, it spams the terminal with repeated messages such as "no active agents", "no issues backing off", and polling countdown updates. That is not a log; it is a broken TUI rendered as text.

Symphony already has a Phoenix dashboard for live state. The terminal should be quiet during idle steady state and should only show ordinary service logs when something useful happens.

## Scope

- Stop `SymphonyElixir.StatusDashboard` from writing periodic status snapshots to stdout.
- Remove terminal frame behavior from the normal runtime path:
  - no `IO.ANSI.home()`;
  - no `IO.ANSI.clear()`;
  - no box drawing;
  - no table header/separator rows;
  - no ANSI color requirement.
- Remove any custom TUI-replacement log formatter from `StatusDashboard`, including helpers that produce `level=... source=... entity=... message=...` lines.
- Use existing `Logger.info/1`, `Logger.warning/1`, and `Logger.error/1` style calls for meaningful events only when the event is not already logged elsewhere.
- If the default console format is not good enough, configure a normal application-level `Logger` formatter for timestamp/level/message presentation.
- Keep messages natural-language and compact, for example:
  - `Retrying MT-456 attempt 4 in 1.250s: rate limit exhausted`
  - `Orchestrator snapshot unavailable`
  - `Codex update for MT-123: turn completed`
- Stay quiet for idle steady state:
  - do not log "no active agents";
  - do not log "no issues backing off";
  - do not log runtime summaries when nothing useful changed;
  - do not log polling countdown changes such as `13s`, `12s`, `11s`.
- Keep the Web dashboard focused on the existing browser summary and tables.
- Remove status-dashboard snapshot fixtures; ordinary logger output should not be maintained as a golden terminal frame.

## Out of Scope

- Adding a generic log/event stream to `/`.
- Adding severity/source/search filters to the Web dashboard.
- Reading persisted events into the main dashboard.
- Adding a new log database schema or retention policy.
- Adding a Symphony-specific status-log schema.
- Adding a formatter that encodes runtime dashboard state instead of ordinary log events.
- Testing Elixir's logger formatter output.
- Replacing Linear diagnostics; diagnostics may keep its own chronological probe log.
- Changing orchestrator dispatch, retry, or Codex app-server behavior except where needed to remove terminal renderer noise.
- Introducing a SPA or Node frontend.

## Acceptance Criteria

- [x] Normal terminal runtime no longer calls `IO.ANSI.home()` or `IO.ANSI.clear()`.
- [x] Normal terminal runtime no longer outputs TUI borders such as `╭`, `├`, `╰`, `│`, or table separator rows.
- [x] `StatusDashboard` no longer emits custom key/value status lines such as `level=... source=... entity=...`.
- [x] Idle steady state produces no stdout/status-log spam.
- [x] Polling countdown changes alone produce no logs.
- [x] Empty-state messages such as "no active agents" and "no issues backing off" are not emitted as periodic logs.
- [x] Meaningful retry, offline, and snapshot-unavailable conditions use normal `Logger` messages when they are not already covered by an existing logger call site.
- [x] Any formatter change is configured through normal `Logger` facilities and applies to ordinary log events, not to hand-built status lines from `StatusDashboard`.
- [x] Web dashboard implementation does not add a main-page event-log table, log filters, or persisted-event feed for this task.
- [x] Existing Web dashboard summary, running sessions, retry queue, navigation, and unavailable-state behavior still render.
- [x] Default tests do not start `SymphonyElixir.Repo` or require SQLite for this work.
- [x] Status-dashboard snapshot fixtures are removed or no longer used for terminal log verification.

## Test Cases

- Render or exercise an idle terminal status path and assert it does not write operational status output to stdout.
- Simulate repeated ticks where only polling countdown changes and assert no additional stdout output is emitted.
- Assert the normal terminal path does not include `IO.ANSI.home()`, `IO.ANSI.clear()`, box borders, or table separator rows.
- If a specific error path must be guarded, use `ExUnit.CaptureLog` only to assert that a useful natural-language message is emitted; do not assert the logger prefix, timestamp, metadata formatting, or full rendered line.
- If a formatter is configured, test only that logging still works at the behavior level; do not lock the exact console rendering unless the project explicitly treats that formatter as a public interface.
- Render `/` and assert the existing dashboard still shows metrics, running sessions, retry queue, live/offline badges, and navigation.
- Assert `/` does not render a generic `Event log` section or `.log-table` introduced by this task.
- Do not add fixture/golden tests for logger output formatting.

## Implementation Notes

- Prefer deleting the terminal renderer path over replacing it with another formatter.
- If `SymphonyElixir.StatusDashboard` remains, it should observe state and broadcast Web dashboard updates; it should not print periodic terminal status output.
- Let the configured Elixir logger backend format level, timestamp, process metadata, and destination.
- A small project-level `Logger` formatter/configuration is acceptable when it improves readability. Keep it generic, for example timestamp, level, message, and selected metadata.
- Add `Logger` calls only where they describe a real event or useful exceptional state and where an existing module is not already logging it.
- Do not log idle snapshots, countdowns, unchanged empty states, or synthetic runtime summaries.
- Do not add a new logging abstraction unless the existing codebase already requires one for this path.
- Keep message humanization by reusing existing Codex event summarization helpers only if that does not reintroduce a status renderer.
- Do not make Web dashboard code depend on terminal logging.
- Do not read `persistence().list_events/1` from the main dashboard for this task.
- Do not test ordinary logger formatting by default; trust `Logger` the same way the project trusts framework logging in other modules.

## Verification

- [x] `mise exec -- mix format --check-formatted`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix build`
- Manual check:
  - start Symphony without active work;
  - confirm the terminal stays quiet after startup instead of printing repeated idle snapshots;
  - create or simulate retry/offline/error state;
  - confirm any emitted terminal output is ordinary logger output, not custom `level=... source=...` status lines;
  - start Symphony with `--port`;
  - confirm the Web dashboard remains the regular dashboard and does not contain a new generic Event Log section.

## Completion Deviations

The earlier draft of this task incorrectly described a custom key/value status stream as "ordinary logs". The implemented target is normal framework logging through `Logger`, with low-noise behavior and no custom terminal status format.

The default console logger handler is kept instead of being removed when the rotating file handler is configured. The console handler uses the same normal `Logger` formatter shape at `:info` level, while the rotating file handler keeps `:all` for deeper diagnostics.

## Dependencies

- Task 004 persisted runtime state, for existing runtime context only.
- Task 016 dashboard color system, because Web dashboard regressions should be avoided.
- Task 021 navigation consistency, because dashboard navigation should remain intact.
- Task 024 diagnostics log visibility lessons, for keeping operator output useful without turning the main dashboard into a log console.
- Task 026 fake persistence boundary, because tests must not depend on Repo/SQLite.

## Handoff Notes

- This task is deliberately terminal-focused.
- Do not implement the plan by adding a log console to Phoenix LiveView.
- Do not implement the plan by appending refreshed status snapshots to stdout.
- Do not implement the plan by inventing a `level=... source=... entity=...` stdout format.
- The terminal should behave like ordinary service logs: quiet when idle, useful when something actually happens, and formatted by `Logger`.
