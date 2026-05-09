# 064 Bootstrap Noninteractive Streaming Diagnostics

## Goal

Make project bootstrap and workspace hooks noninteractive, observable while they
run, and diagnosable when they are slow or stuck.

## Status

Completed.

## Background

Recent local runs for `CCR-3` repeatedly failed with:

```text
{:workspace_hook_timeout, "project_bootstrap", 300000}
```

The active workflow was configured with:

- `project.repository_url`: `git@github.com:VikingMew/claude-code-router-rust.git`
- `project.default_branch`: `master`
- `project.checkout_depth`: `1`
- `project.setup_commands`: `[]`
- `hooks.timeout_ms`: `300000`

The generated bootstrap command therefore ran a shallow `git clone` into the
issue workspace. The workspace contained only `.git` while the run was timing
out, which means the clone had started but had not produced a completed working
tree. Manual probing showed `git ls-remote` succeeded and the branch existed,
but the full clone could run for a long time without visible output.

The problem is a class of failures, not a single repository issue:

- git or SSH may wait for credentials, host-key confirmation, proxy access, or
  network progress;
- `System.cmd/3` only returns command output after the command exits, so
  operators cannot tell whether bootstrap is downloading, waiting for input, or
  wedged;
- timeout failures lose important context such as the exact command, recent
  output, elapsed time, and whether the workspace is a partial clone.

## Scope

- Generate project bootstrap clone commands with noninteractive git/SSH
  defaults.
- Ensure git cannot prompt indefinitely for credentials or host-key input during
  Symphony-managed bootstrap.
- Stream bounded hook output to logs and persisted events while the command is
  running.
- Include recent output, command label, elapsed time, timeout, workspace path,
  and worker host in hook timeout errors.
- Distinguish generated `project_bootstrap` output from custom lifecycle hooks
  in both logs and events.
- Cover local hook execution first; preserve remote worker behavior, and add a
  follow-up note if remote streaming needs a separate transport-level design.
- Add focused tests for noninteractive clone command generation, streaming
  event persistence, and timeout diagnostics.

## Out of Scope

- Replacing git clone with a full custom Git client.
- Changing Linear workflow states or retry policy.
- Adding repository-specific mirrors or cache management.
- Solving all network performance problems for GitHub or internal git servers.
- Changing user-configured `setup_commands` semantics beyond the shared
  noninteractive environment and streaming output behavior.

## Acceptance Criteria

- Generated project bootstrap clone commands set noninteractive git behavior,
  including `GIT_TERMINAL_PROMPT=0`.
- SSH clone paths use a noninteractive SSH command, for example `BatchMode=yes`
  and a bounded connect timeout, without breaking HTTPS clone paths.
- Long-running hooks emit periodic bounded output events that are visible from
  run/event detail pages.
- A `project_bootstrap` timeout includes at least:
  - hook name;
  - timeout in milliseconds;
  - elapsed time;
  - workspace path;
  - worker host;
  - sanitized command label or command preview;
  - recent captured output.
- Timeout and failure output is sanitized so secrets, tokens, and authorization
  values are not persisted or rendered.
- Existing custom hooks still execute in the configured order:
  `project_bootstrap`, then `hooks.after_create`.
- Tests cover a command that prints output and sleeps long enough to prove
  streaming occurs before process exit.
- Tests cover a timeout and assert the timeout reason carries recent output.
- Tests cover clone command generation for SSH and HTTPS repository URLs.
- `mise exec -- mix test` passes.
- `mise exec -- mix lint` passes.
- Coverage remains above 80%.

## Test Cases

- Unit test `Config.generated_after_create_hook/1` for SSH repository URLs:
  generated command includes `GIT_TERMINAL_PROMPT=0`, a noninteractive
  `GIT_SSH_COMMAND`, branch, depth, repository URL, and destination `.`.
- Unit test HTTPS repository URLs:
  generated command includes `GIT_TERMINAL_PROMPT=0` but does not force SSH-only
  configuration.
- Workspace hook test with a shell command that emits multiple lines over time:
  events/log capture incremental output before final success.
- Workspace hook timeout test:
  command emits a marker and sleeps past timeout; returned error contains the
  marker in recent output.
- Redaction test:
  output containing token-like keys is sanitized before being persisted.
- Regression test:
  both structured bootstrap and `hooks.after_create` still run in order.

## Implementation Notes

- Prefer a small reusable hook runner abstraction over expanding
  `Workspace.run_hook/5` inline. It should support:
  - process start with environment overrides;
  - bounded line/chunk capture;
  - event persistence callback;
  - timeout shutdown;
  - sanitized recent-output buffer.
- For local execution, consider `Port.open/2` or another streaming mechanism
  instead of `System.cmd/3`, because `System.cmd/3` cannot expose output before
  command exit.
- Keep output bounded to avoid large database rows. A ring buffer of recent
  bytes or recent lines is enough for diagnostics.
- Include issue context when persisting events so `/runs/:id`, `/issues/:id`,
  and `/events` can filter hook activity.
- Reuse or align with the existing event payload scrubber used by the web
  observability pages.
- Be careful with shell quoting. Existing `shell_escape/1` should remain the
  default for repository URL and branch values.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix test`
- `mise exec -- mix test --cover`
- `git diff --check`

Coverage result: `83.40%` total.

## Completion Deviations

- Local hook execution now uses `Port.open/2` directly in `Workspace` instead
  of extracting a separate hook runner module. The resulting code is still
  bounded and test-covered, and avoids introducing an abstraction before remote
  hook streaming is designed.
- Remote worker hooks remain result-based rather than streaming. This matches
  the plan scope to preserve remote behavior and leaves remote transport-level
  streaming as a future enhancement.

## Dependencies

- Completed plan 059, which ensures structured project bootstrap runs before
  custom `hooks.after_create`.
- Completed plan 061, which made logs distinguish `project_bootstrap` from
  custom hooks.
- Completed plan 062, which added run, issue, and event observability pages.

## Handoff Notes

This plan should make the next `CCR-3` bootstrap failure explain itself while
it is happening. The immediate operational workaround remains increasing
`hooks.timeout_ms` or improving git network/proxy access, but the product should
not require operators to wait five minutes to learn that clone is still running
or waiting for input.
