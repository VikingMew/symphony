# 053 Codex App Server Startup Error Context

## Goal

Make Codex app-server startup failures actionable by returning the command, exit status, and captured stderr/stdout snippet instead of only `{:port_exit, status}`.

## Status

Completed.

## Background

When Symphony launches Codex locally, `Codex.AppServer` starts `bash -lc <codex.command>` and then waits for the app-server JSON-RPC handshake. If the shell exits before or during startup, the current error can be only:

```elixir
{:port_exit, 127}
```

Exit code `127` usually means the configured command was not found, but the operator cannot see which command failed or what the shell printed. This makes common environment problems, such as Node/NVS not being initialized before `codex app-server`, hard to diagnose from logs.

## Scope

- Capture startup stderr/stdout emitted before a successful Codex handshake.
- Return a structured error that includes:
  - exit status;
  - configured `codex.command`;
  - workspace;
  - worker host when present;
  - a bounded output snippet.
- Preserve existing turn-time behavior once a session has started.
- Log the improved startup failure through existing `AgentRunner` and `Codex.AppServer` paths.
- Keep sensitive environment values out of captured output and logs as much as practical.
- Add tests for a missing command / exit 127 startup failure.

## Out of Scope

- Changing how `codex.command` is configured.
- Managing Node/NVS installation.
- Adding a dedicated command-builder UI.
- Changing workspace hook error handling.
- Changing Codex JSON-RPC protocol handling after a session has already started.

## Acceptance Criteria

- A missing Codex executable reports an error that includes `exit_status: 127` and a short output snippet such as `command not found`.
- The error includes the configured `codex.command` so the operator can identify the broken command.
- The output snippet is bounded to avoid flooding logs.
- Existing app-server happy-path tests still pass.
- Existing turn-time `{:port_exit, status}` behavior is not accidentally broken for already-started sessions, unless intentionally improved with compatible tests.

## Test Cases

- Configure `codex.command` to a command that exits 127 with stderr; `start_session/2` returns an error containing status, command, workspace, and output.
- Configure fake Codex app-server happy path; session starts and turns still complete.
- Configure a startup command that emits a large output before exit; returned snippet is truncated.
- Verify sensitive env variables are still scrubbed from the child process environment.

## Implementation Notes

- The current local launch path uses a line-oriented `Port.open` with `stderr_to_stdout`.
- During `do_start_session/3`, collect non-JSON output lines until either:
  - initialization succeeds; or
  - the port exits; or
  - startup timeout occurs.
- Consider a helper such as `startup_failure(reason, metadata, buffered_output)`.
- Do not log raw unbounded process output.
- Exit 127 should get a human-oriented hint: command not found or shell initialization failed.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `git diff --check`

## Completion Deviations

Startup failures now return `{:codex_startup_failed, details}` during initialize/thread startup, including command, workspace, worker host, timeout, exit status, bounded output, and a hint. The implementation also covers startup response timeouts, not only exit 127.

## Dependencies

- Related to Task 031 runtime proxy env support.
- Related to Task 034 Codex sensitive environment scrubbing.

## Handoff Notes

The immediate user-facing failure is `{:port_exit, 127}` when `codex` is installed only after shell initialization such as NVS. The implementation should not assume NVS specifically; it should expose enough process output for any missing-runtime command failure to be obvious.
