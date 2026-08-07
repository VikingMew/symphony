# 078 Remove CLI Guardrails Ack Flag

## Goal

Remove the mandatory `--i-understand-that-this-will-be-running-without-the-usual-guardrails` startup flag from the Symphony CLI. Starting Symphony should use ordinary commands such as `./bin/symphony` or `./bin/symphony --port 4000` without a long acknowledgement flag.

## Context

The current CLI treats the acknowledgement flag as a process startup safety gate. `CLI.evaluate/2` checks it before workflow path resolution, port setup, logs root setup, or app startup. This makes every documented command noisy and suggests the flag is a real runtime configuration level, even though it is not part of workflow, profile, or Settings configuration.

The desired behavior is a normal CLI: warnings and operational constraints can remain documented, but startup should not require a special acknowledgement argument.

## Scope

- Remove the acknowledgement switch from CLI option parsing.
- Remove the acknowledgement check from all CLI startup paths.
- Remove the acknowledgement banner and related helper code.
- Update CLI usage text and examples so the long flag is no longer shown.
- Update tests that currently expect missing-flag failure.
- Add or update tests proving these commands can start through `CLI.evaluate/2` without the acknowledgement flag:
  - default `./bin/symphony` path resolution
  - `--port <port>` dashboard-first startup
  - `--logs-root <path>` startup
- Keep unknown flag handling intact: passing the removed long flag should now be rejected as invalid CLI usage.
- Update user-facing docs and project docs to remove the flag from copy/paste commands.

## Non-Goals

- Do not change workflow source precedence.
- Do not change file mode vs database mode behavior.
- Do not add a replacement environment variable or Settings toggle for this acknowledgement.
- Do not remove runtime warnings about unsupported or preview behavior if those warnings are useful elsewhere.
- Do not change Codex sandbox, approval, or Linear permission behavior.

## Acceptance Criteria

- [x] `CLI.evaluate([])` can proceed without failing on a missing acknowledgement flag.
- [x] `CLI.evaluate(["--port", "4000"])` can proceed to database dashboard mode without failing on a missing acknowledgement flag.
- [x] `CLI.evaluate(["--logs-root", "log"])` can proceed without failing on a missing acknowledgement flag.
- [x] `CLI.evaluate(["--i-understand-that-this-will-be-running-without-the-usual-guardrails"])` returns the normal usage error for an unknown/invalid option.
- [x] No user-facing startup command in README or docs includes the removed flag.
- [x] Tests cover the removed flag behavior and the supported flagless startup paths.

Note: 079 removes positional workflow path startup, so explicit workflow path startup is intentionally no longer a supported flagless path.

## Test Plan

- Update `test/symphony_elixir/cli_test.exs`.
- Search docs and code for the removed flag string and remove active references.
- Run:
  - `mise exec -- mix test test/symphony_elixir/cli_test.exs`
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- The CLI parser currently declares the acknowledgement switch in `SymphonyElixir.CLI.@switches`; remove it from there first.
- Removing the switch means the old flag should naturally fall into the existing usage error path.
- Keep the startup API shape small: `evaluate/2`, `run_default/2`, and `run/2` should not grow new confirmation parameters.
- After the change, startup safety should be communicated in documentation and logs, not by a mandatory command-line acknowledgement.
