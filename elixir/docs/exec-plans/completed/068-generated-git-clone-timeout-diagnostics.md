# 068 Generated Git Clone Timeout Diagnostics

## Goal

Make generated `project_bootstrap` clone commands fail faster and with clearer
diagnostics when Git authentication or network transport stalls after
`Cloning into '.'...`.

## Status

Completed.

## Background

The generated structured project bootstrap already sets `GIT_TERMINAL_PROMPT=0`
and, for SSH URLs, `GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10
...'`. A real run still timed out at the workspace-hook level after five
minutes with only:

```text
Cloning into '.'...
```

This means the clone entered Git transport but did not fail or produce useful
progress before the outer hook timeout. Noninteractive prompt prevention is not
enough; the generated command also needs Git HTTP low-speed timeout options,
SSH keepalive limits, disabled askpass helpers, and progress output.

## Scope

- Update the generated `project_bootstrap` clone command.
- Keep support for HTTPS and SSH repository URLs.
- Preserve existing `project.default_branch` and `project.checkout_depth`
  behavior.
- Disable Git credential helpers and askpass prompts for generated clone
  commands.
- Add Git HTTP low-speed timeout settings so HTTPS stalls fail before the outer
  hook timeout.
- Add SSH keepalive options so SSH stalls fail before the outer hook timeout.
- Add `--progress` to generated clone commands so runtime output has more
  chance of explaining where clone is stuck.
- Update regression tests for generated clone command contents.

## Out of Scope

- Replacing Git with a custom clone client.
- Adding proxy configuration UI.
- Retrying clone inside the hook.
- Changing user-authored custom hooks.

## Acceptance Criteria

- Generated HTTPS clone command includes:
  - `GIT_TERMINAL_PROMPT=0`;
  - disabled askpass environment;
  - `git -c credential.helper= -c core.askPass= -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone --progress ...`.
- Generated SSH clone command includes the above Git options and
  `GIT_SSH_COMMAND` with `BatchMode`, `ConnectTimeout`, `ServerAliveInterval`,
  and `ServerAliveCountMax`.
- Existing branch/depth/repository URL behavior is unchanged.
- Focused workspace/config tests pass.
- `mise exec -- mix lint` passes.
- `mise exec -- mix test` passes.

## Test Cases

- Generated SSH bootstrap command contains SSH noninteractive and keepalive
  options.
- Generated HTTPS bootstrap command contains Git HTTP low-speed timeout options.
- Existing generated clone command still includes `--depth`, `--branch`, repo
  URL, and destination `.`.

## Implementation Notes

- The implementation point is
  `SymphonyElixir.Config.Schema.maybe_append_clone_command/2`.
- Prefer Git's native `-c` options over shell-specific timeout wrappers.
- The outer workspace hook timeout remains a final guardrail.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
  - 50 tests, 0 failures
- `mise exec -- mix lint`
  - no issues
- `mise exec -- mix test`
  - 288 tests, 0 failures, 2 skipped

## Completion Deviations

- The implementation uses Git-native `-c` HTTP low-speed options and SSH
  keepalive options instead of an external `timeout` command. This keeps the
  generated hook portable and avoids depending on a particular coreutils
  package.
- The hook still has the outer workspace timeout as a final guardrail.

## Dependencies

- Completed plan
  [064-bootstrap-noninteractive-streaming-diagnostics.md](../completed/064-bootstrap-noninteractive-streaming-diagnostics.md).

## Handoff Notes

This does not guarantee that an unreachable repository succeeds. It makes the
generated clone fail faster and emit more useful output so operators can fix
credentials, proxy, branch, or network access without waiting for the five
minute hook timeout.
