# 101 Codex Pre-Start Commands

## Goal

Add an editable Codex startup preparation field so operators can run shell commands in the same shell that launches `codex app-server`. This supports environment managers such as `nvs`, `mise`, `asdf`, or custom PATH setup before Symphony starts Codex.

## Status

Completed.

## Background

Today the practical workaround for "Codex command not found" is to put everything into `codex.command`, for example:

```sh
bash -lc 'source ~/.nvs/nvs.sh && nvs use 22 >/dev/null && exec codex app-server'
```

That works, but it makes the command field hard to read and mixes two separate concepts:

- environment preparation before Codex starts;
- the actual Codex app-server command.

Lifecycle hooks such as `before_run` are not the right place for this. They run as separate workspace hooks and cannot reliably change the environment of the later Codex app-server process. The pre-start commands must run in the same shell process chain as the Codex command.

## Scope

- Add a workflow config field under `codex`, for example:

```yaml
codex:
  pre_start_commands:
    - source ~/.nvs/nvs.sh
    - nvs use 22 >/dev/null
  command: codex --config shell_environment_policy.inherit=all app-server
```

- Add a Settings / Workflow / Codex editor control for the pre-start commands.
- Treat the field as an ordered list of shell command lines.
- Compose startup as:
  - enter workspace cwd;
  - apply runtime proxy/safe env handling;
  - run each pre-start command in order;
  - `exec` the configured Codex command.
- Ensure local and remote worker startup use the same semantics.
- Preserve the existing sensitive environment scrubbing behavior.
- Show startup failure context that identifies whether failure happened in a pre-start command or in Codex app-server startup.
- Document common examples:
  - `source ~/.nvs/nvs.sh`
  - `nvs use 22 >/dev/null`
  - `mise trust && mise exec -- true`
  - `export PATH="$HOME/.local/bin:$PATH"`

## Out of Scope

- Do not use lifecycle hooks for Codex environment preparation.
- Do not automatically install Node, Codex, nvs, mise, or other tools.
- Do not store secrets in pre-start commands.
- Do not change project source preparation or git sync behavior in this plan.
- Do not make pre-start commands project-specific unless a later plan explicitly adds project-level Codex runtime policy.

## Acceptance Criteria

- Settings exposes a Codex pre-start commands textarea/list near the Codex command field.
- Saved workflow versions persist `codex.pre_start_commands`.
- On agent startup, every configured pre-start command runs before `codex.command`.
- The commands run in the same shell context as the final Codex launch so PATH/version-manager changes affect `codex`.
- The final launch uses `exec` so process lifecycle remains tied to the Codex app-server process.
- Local and remote worker launch paths both honor pre-start commands.
- If a pre-start command fails, Codex is not started and the error clearly identifies the failed pre-start stage.
- If `codex.command` is still not found, the existing startup hint remains visible.
- Default empty pre-start commands preserve current behavior.

## Test Cases

- Workflow form loads/saves `codex.pre_start_commands` as newline-separated commands in the UI and an array in config.
- Empty pre-start commands produce the same launch command as before.
- Local launch command includes pre-start commands before `exec codex...`.
- Remote launch command includes pre-start commands before `exec codex...`.
- A failing pre-start command produces a startup failure classified as Codex pre-start failure and does not attempt the app-server handshake.
- A successful pre-start command that modifies PATH allows the following command lookup to use that PATH.
- Sensitive environment scrubbing still runs before Codex launch and does not leak token values in logs.

## Implementation Notes

- This belongs under the Codex section of workflow settings, not under Lifecycle Hooks.
- Prefer storing `pre_start_commands` as an array of strings, matching existing project setup command shape.
- UI can use a fixed-size textarea with one command per line, consistent with setup commands.
- The command composition should avoid double-shell surprises. A safe local shape is:

```sh
cd <workspace> && <proxy exports> && <unset sensitive env> && <pre-start command 1> && ... && exec <codex.command>
```

- If a command needs shell functions like `nvs`, users can write `source ~/.nvs/nvs.sh` as an earlier pre-start command.
- Error messages should include the Settings path: `Settings / Workflow / Codex / Pre-start commands`.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- Focused tests for workflow form config roundtrip and local/remote Codex launch command composition.
- `git diff --check`

## Completion Deviations

Implemented as `codex.pre_start_commands`, edited from Settings / Workflow / Codex as a newline-separated textarea and persisted as an ordered list.

The normal simple Codex command path now launches through the same shell script and prefixes the final command with `exec`. Existing shell-control test commands that contain separators/newlines are preserved as shell snippets so legacy test harness scripts continue to run as intended.

Focused tests cover PATH preparation, failing pre-start commands stopping before Codex launch, remote launch command composition, and config default/roundtrip behavior.

## Dependencies

- Completed plan 034 for Codex sensitive env scrubbing.
- Completed plan 053 for Codex app-server startup error context.
- Completed plan 081 and 082 for Settings layout usability.
- Completed plan 098 for current Settings draft/save behavior.

## Handoff Notes

The key point is that these commands must affect the actual Codex app-server process. Do not implement this as `before_run`; that hook is useful for workspace preparation, but it cannot reliably change the environment of a later process. The operator should be able to keep `codex.command` readable while putting version-manager setup in a dedicated pre-start field.
