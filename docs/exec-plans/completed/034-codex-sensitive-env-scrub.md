# Task 034: Codex Sensitive Environment Scrubbing

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 031
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Ensure Codex app-server child processes do not receive Linear, tracker, or unrelated external-service secrets through inherited environment variables.

## Background

Codex should interact with Linear through restricted Symphony tools, not by reading `LINEAR_API_KEY` from its process environment. Runtime proxy support intentionally passes proxy variables to Codex, but secret inheritance needs the opposite policy: deny known sensitive variables by default and only allow explicitly safe runtime variables.

## Scope

- Add environment filtering for local `Port.open` Codex launch.
- Add equivalent filtering/export behavior for SSH remote Codex launch.
- Preserve runtime proxy variables from Task 031.
- Remove `LINEAR_API_KEY`, `LINEAR_TOKEN`, tracker token variables, and common external service tokens from Codex child environments.
- Add tests that fake Codex and assert sensitive variables are absent while proxy variables remain present.
- Document the environment policy.

## Out of Scope

- Managing Codex auth files.
- Removing secrets from the parent Symphony process.
- Full secret manager integration.
- Auditing arbitrary workspace hook environments.

## Acceptance Criteria

- [ ] Local Codex child process does not receive `LINEAR_API_KEY`.
- [ ] Local Codex child process still receives allowed proxy env vars.
- [ ] Remote SSH launch does not export Linear/tracker secrets.
- [ ] The policy is centralized and easy to extend.
- [ ] Existing app-server tests still pass.
- [ ] Docs state that Codex cannot rely on Linear token env.

## Test Cases

- Set `LINEAR_API_KEY`, launch fake local Codex, assert fake process sees it as empty.
- Set `HTTPS_PROXY`, launch fake local Codex, assert fake process sees it.
- Set lowercase proxy variables, assert they are preserved.
- Build remote launch command under env with `LINEAR_API_KEY`, assert command does not contain it.
- Existing proxy tests from Task 031 still pass.

## Implementation Notes

- Prefer allowlist for env values passed explicitly to `Port.open`.
- If a denylist is simpler with current BEAM port behavior, include common names:
  - `LINEAR_API_KEY`
  - `LINEAR_TOKEN`
  - `GITHUB_TOKEN`
  - `GH_TOKEN`
  - `SLACK_BOT_TOKEN`
  - `OPENAI_API_KEY` only if Codex auth does not require it in this deployment model.
- Avoid logging env values.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix compile --warnings-as-errors`
- [ ] `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

Implemented local child-process scrubbing with explicit unset entries and remote launch scrubbing with `unset`. Proxy environment propagation remains allowed.

## Dependencies

- Task 031 added runtime proxy propagation and should not be regressed.

## Handoff Notes

This task is independently useful even before restricted tools land because it closes the most direct secret exposure path.
