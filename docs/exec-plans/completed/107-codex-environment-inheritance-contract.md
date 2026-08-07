# 107 Codex Environment Inheritance Contract

## Goal

Define and enforce a safer Codex app-server environment contract so repo-local workflow examples do not depend on broad shell environment inheritance.

## Status

Completed.

## Background

The repo-local `workflow.yml` currently launches Codex with:

```text
codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
```

At the same time, `lib/symphony_elixir/codex/app_server.ex` contains sensitive environment filtering, and the project documentation says Codex should not receive credentials such as `LINEAR_API_KEY`. The launcher may scrub sensitive process env, but the example command still communicates a broad inheritance posture. That makes the security model harder to reason about and increases the chance that command-level Codex config and Symphony process filtering drift apart.

## Scope

- Decide the minimal environment needed by repo-local Codex runs.
- Replace broad `shell_environment_policy.inherit=all` in example workflow config if it is not required.
- Document when `codex.pre_start_commands` should be used for PATH/runtime setup.
- Add regression coverage that sensitive environment values are not passed to launched Codex processes, even when workflow command config asks for broad inheritance.
- Keep proxy inheritance behavior explicit, since runtime proxy support is intentional.

## Out of Scope

- Removing all environment inheritance from Codex.
- Changing operator-provided credentials outside the Codex launch boundary.
- Replacing Codex app-server configuration semantics.
- Changing approval-policy or sandbox behavior.

## Acceptance Criteria

- The bundled `workflow.yml` no longer recommends broad env inheritance unless a documented requirement remains.
- Docs describe the supported way to prepare PATH and runtime dependencies through `codex.pre_start_commands`.
- Sensitive env scrubbing is tested at the final launch boundary.
- Proxy variables that are intentionally propagated remain documented and tested.
- The app-server still starts successfully in local and SSH centralized modes.

## Test Cases

- App-server launch test sets `LINEAR_API_KEY`, `OPENAI_API_KEY`, `GITHUB_TOKEN`, and proxy variables; assert sensitive values are scrubbed while intended proxy values are preserved.
- Command construction test proves `pre_start_commands` and `codex.command` run in the intended shell order.
- Workflow package validation test proves the repo-local command remains valid after removing or narrowing env inheritance.
- SSH launch test or existing fake proves remote launch command applies the same env contract.

## Implementation Notes

- First determine why `inherit=all` was added. If it only works around PATH or shell init, move that guidance to `codex.pre_start_commands`.
- Keep runtime proxy behavior aligned with `RuntimeProxy`; do not accidentally remove `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, or `NO_PROXY` propagation where documented.
- Avoid logging raw env values. Tests should inspect scrubbed launch metadata or controlled fake launch commands.
- Consider an allowlist-oriented command example if Codex supports it in the target app-server version.
- Keep `workflow.yml` as an import/export artifact, but make it a safe artifact because operators copy it during setup.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/runtime_proxy_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

The repo-local workflow command no longer recommends `shell_environment_policy.inherit=all`. README guidance now directs PATH/runtime setup to `codex.pre_start_commands`, while existing app-server tests continue to cover sensitive environment scrubbing and proxy preservation at the launch boundary.

## Dependencies

- Plan 031 for runtime proxy env support.
- Plan 034 for Codex sensitive env scrubbing.
- Plan 101 for Codex pre-start commands.
- Plan 104 for the original audit finding.

## Handoff Notes

This is a boundary-hardening plan. The key is not only whether current code scrubs secrets, but whether the repo-local workflow contract teaches operators to rely on a minimal and understandable launch environment.
