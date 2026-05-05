# Task 027: Log-Oriented Terminal Status Output

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Tasks 004, 016, 021, 024, 026
**Created**: 2026-05-05
**Completed**: 2026-05-05

## Goal

Replace Symphony's terminal TUI-style status presentation with ordinary line-oriented log output.

This task is about the runtime/operator output emitted by `SymphonyElixir.StatusDashboard` in the terminal. It is not a Web dashboard task. The Phoenix dashboard should continue to show the existing operational summary, running sessions, retry queue, and related pages; it should not gain a new generic event-log table or log filtering UI as part of this task.

The terminal output should answer operator questions in a grep-friendly form:

- What happened most recently?
- Which issue/session/run did it happen to?
- Was it informational, warning, or error?
- Which component produced the line?
- What compact runtime metadata explains the result?

## Background

The current `StatusDashboard` terminal output behaves like a live TUI frame: it clears the terminal, moves the cursor home, draws box borders, and renders compact tables for running agents and retry state. That is useful for a glanceable local display, but it is weak for debugging long-running services because useful information disappears when the frame redraws and the output is awkward to search, capture, or ship to a log sink.

Symphony already has an optional Phoenix dashboard for rich browser-based observation. Terminal output should therefore bias toward durable logs rather than another interactive UI surface.

## Scope

- Change `SymphonyElixir.StatusDashboard` terminal rendering to append ordinary log-style lines.
- Remove primary-output dependence on terminal frame behavior:
  - no cursor-home writes;
  - no terminal clear writes;
  - no box drawing or table chrome as the main status surface.
- Emit stable key/value-style lines for:
  - runtime summary;
  - Linear project URL;
  - optional dashboard URL;
  - polling/refresh state;
  - rate-limit summary;
  - running issue/session last Codex activity;
  - retry queue entries;
  - offline state;
  - orchestrator snapshot-unavailable state.
- Keep each status event on one physical line so output works with shell logs, `grep`, `tail`, and CI captures.
- Sanitize newlines and escaped newline sequences in messages and retry errors.
- Keep terminal colors if useful, but ensure the plain text remains readable after ANSI stripping.
- Replace terminal snapshot fixture coverage with direct behavior assertions for line-oriented log fields.
- Remove the status-dashboard snapshot fixtures so this log output is not treated like a terminal UI golden file.
- Keep Web dashboard behavior focused on the existing browser summary and tables.

## Out of Scope

- Adding a generic log/event stream to `/`.
- Adding severity/source/search filters to the Web dashboard.
- Reading persisted events into the main dashboard.
- Adding a new log database schema or retention policy.
- Replacing Linear diagnostics; diagnostics may keep its own chronological probe log.
- Changing orchestrator dispatch, retry, or Codex app-server behavior.
- Introducing a SPA or Node frontend.

## Acceptance Criteria

- [x] `StatusDashboard` terminal output no longer writes `IO.ANSI.home()` or `IO.ANSI.clear()` during normal rendering.
- [x] Normal terminal status output no longer uses TUI borders such as `╭`, `├`, `╰`, or table separator rows as the primary display.
- [x] Runtime summary is emitted as a stable log line with agent count, retry count, throughput, runtime, and token metadata.
- [x] Running sessions are emitted as log lines with issue identifier, state, session, PID, runtime/turns, token count, last event, and message.
- [x] Retry queue entries are emitted as warning log lines with issue identifier, attempt, due time, and sanitized error text.
- [x] Empty running/retry states are represented as ordinary informational log lines.
- [x] Offline and snapshot-unavailable states are represented as ordinary log lines.
- [x] Log values are sanitized so embedded newlines and escaped newline sequences do not split a single status event across multiple terminal lines.
- [x] Web dashboard implementation does not add a main-page event-log table, log filters, or persisted-event feed for this task.
- [x] Existing Web dashboard summary, running sessions, retry queue, navigation, and unavailable-state behavior still render.
- [x] Default tests do not start `SymphonyElixir.Repo` or require SQLite for this work.

## Test Cases

- Render the idle terminal status payload and assert it uses line-oriented log output.
- Render a busy terminal status payload and assert each running session appears as a log line.
- Render retry pressure and assert every queued retry appears as a warning log line.
- Render a retry error containing `\n` and assert the rendered output remains one line for that retry.
- Render snapshot unavailable and assert an error log line is emitted.
- Render offline status and assert an error log line is emitted.
- Assert normal terminal rendering does not include `IO.ANSI.home()`, `IO.ANSI.clear()`, box borders, or table separator rows in expected output.
- Render `/` and assert the existing dashboard still shows metrics, running sessions, retry queue, live/offline badges, and navigation.
- Assert `/` does not render a generic `Event log` section or `.log-table` introduced by this task.

## Implementation Notes

- Keep the change centered in `SymphonyElixir.StatusDashboard`.
- Prefer one small formatter for terminal log lines, with a shape similar to:
  - `level=<level>`
  - `source=<component>`
  - `entity=<issue/session/runtime>`
  - `message="<summary>"`
  - additional metadata as sorted `key="value"` pairs
- Keep message humanization by reusing existing Codex event summarization helpers.
- Reuse existing rate-limit and runtime formatting helpers where they produce concise text.
- Do not make Web dashboard code depend on this terminal log projection.
- Do not read `persistence().list_events/1` from the main dashboard for this task.
- Use targeted assertions for stable log fields instead of snapshot fixtures. The log output should be searchable and structurally stable, but it should not be locked to a large golden terminal frame.

## Verification

- [x] `mise exec -- mix format --check-formatted`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix build`
- Manual check:
  - start Symphony without `--port`;
  - confirm terminal output appends ordinary log lines instead of redrawing a TUI frame;
  - start Symphony with `--port`;
  - confirm the Web dashboard remains the regular dashboard and does not contain a new generic Event Log section.

## Completion Deviations

None expected. If Web dashboard files changed during implementation, those changes should only remove accidental log UI work or keep existing unrelated dashboard behavior compiling.

## Dependencies

- Task 004 persisted runtime state, for existing runtime context only.
- Task 016 dashboard color system, because Web dashboard regressions should be avoided.
- Task 021 navigation consistency, because dashboard navigation should remain intact.
- Task 024 diagnostics log visibility lessons, for terminal log line design only.
- Task 026 fake persistence boundary, because tests must not depend on Repo/SQLite.

## Handoff Notes

- This task is deliberately terminal-focused.
- Do not implement the plan by adding a log console to Phoenix LiveView.
- The desired operator experience is `tail`/`grep`-friendly terminal logs, while the browser dashboard remains a separate summary/control surface.
