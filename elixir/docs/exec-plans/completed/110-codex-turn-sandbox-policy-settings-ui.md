# 110 Codex Turn Sandbox Policy Settings UI

## Goal

Expose `codex.turn_sandbox_policy` in Settings so operators can configure the sandbox policy that
is actually sent to `codex app-server` for each agent turn. The UI should make it clear that
`thread_sandbox` and `turn_sandbox_policy` are different settings, and that push/network operations
depend on the turn-level policy.

## Status

Completed.

## Background

The current `/settings/workflow` Codex section exposes:

- `codex.command`
- `codex.pre_start_commands`
- `codex.approval_policy`
- `codex.thread_sandbox`

However, runtime also supports and sends `codex.turn_sandbox_policy` in `turn/start` as
`sandboxPolicy`. This field controls turn-level filesystem/network behavior. In practice, a user can
change `thread_sandbox` to `danger-full-access` in the UI while the active workflow still contains a
turn policy such as:

```yaml
turn_sandbox_policy:
  type: workspaceWrite
```

That leaves agent turns unable to perform required network operations such as `git push`, even
though the visible UI appears to have been relaxed. This is a configuration visibility gap rather
than a Codex command/model parameter issue.

The code path already preserves unknown or non-rendered config through `_base_config`, so the field
can exist and remain active without being editable from the structured form. That makes the behavior
hard to discover and hard to fix without YAML import or direct database/workflow manipulation.

## Scope

- Add a structured UI control in `/settings/workflow` / Codex for `codex.turn_sandbox_policy`.
- Support at least these operator-facing presets:
  - Workspace write, no network: `type: workspaceWrite`, `networkAccess: false`
  - Workspace write, network enabled: `type: workspaceWrite`, `networkAccess: true`
  - Danger full access: `type: dangerFullAccess`
- Keep `codex.thread_sandbox` visible, but label or group it so users understand it is not the same
  as the turn policy.
- Ensure saving the structured workflow form writes the selected `turn_sandbox_policy` into the
  active workflow version.
- Ensure importing a workflow package with `codex.turn_sandbox_policy` populates the UI state.
- Ensure exporting or rendering the workflow package preserves the selected policy.
- Add validation/error messages that point to the Codex section when the policy is malformed.
- Update user docs to explain which setting controls push/network access during agent turns.

## Out of Scope

- Do not change the default sandbox posture in this plan.
- Do not automatically grant network access to all existing workflows.
- Do not redesign Codex approval policy.
- Do not add GitHub credential management or push automation.
- Do not remove the existing advanced map passthrough behavior unless a replacement advanced editor
  is included.

## Acceptance Criteria

- Operators can configure `codex.turn_sandbox_policy` from Settings without editing YAML or the
  database directly.
- Selecting `dangerFullAccess` causes subsequent `turn/start` payloads to send:

```json
{"type": "dangerFullAccess"}
```

- Selecting workspace write with network sends a `workspaceWrite` policy with network access enabled.
- The UI no longer implies that changing only `thread_sandbox` is sufficient for turn-level network
  operations.
- Existing active workflow versions with `turn_sandbox_policy` display the current effective value.
- Saving unrelated Workflow settings does not silently erase or downgrade the turn sandbox policy.
- Invalid or unsupported turn sandbox maps produce actionable Settings errors.

## Test Cases

- `WorkflowForm.from_loaded/1` maps existing `codex.turn_sandbox_policy` into draft state.
- `WorkflowForm.to_config/1` writes the selected turn sandbox policy back under `codex`.
- Web Settings test: changing the turn sandbox preset to danger full access persists
  `%{"type" => "dangerFullAccess"}`.
- Web Settings test: changing only `thread_sandbox` does not overwrite an existing turn policy.
- App server test: active danger full access turn policy is sent as `sandboxPolicy` in `turn/start`.
- Import/export test: a workflow package containing `turn_sandbox_policy` round-trips through the
  structured form.

## Implementation Notes

- The current form only has `codex_thread_sandbox`; add separate draft fields for turn sandbox.
- Prefer a preset selector for common policies, plus an optional advanced JSON/YAML textarea if the
  product still wants to pass through future Codex sandbox shapes.
- The danger preset should use Codex's app-server payload shape `dangerFullAccess`, while
  `thread_sandbox` continues to use the thread-level string value `danger-full-access`.
- The copy should avoid implying that `approval_policy: never` enables network access. Approval and
  sandbox/network are separate controls.
- If an existing policy is an unrecognized map, preserve it and show it in advanced mode rather than
  normalizing it to a safer preset without user intent.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- Manual browser check on `/settings/workflow`:
  - current active turn policy is visible;
  - saving danger full access persists;
  - reloading the page shows the same value;
  - a subsequent agent turn receives the expected `sandboxPolicy`.

## Completion Deviations

- The structured UI uses a preset selector plus a custom JSON textarea. The custom textarea remains
  visible so existing future Codex sandbox shapes can be inspected and preserved instead of silently
  normalized.
- The workspace-write presets intentionally omit `writableRoots`; runtime still resolves safe
  default roots when no explicit custom map is required. Operators can use Custom JSON for explicit
  roots.
- Manual browser verification was covered by LiveView integration tests in this pass.

## Dependencies

- Completed plan 102 for current Codex approval policy enum behavior.
- Existing Codex app-server integration that already sends `sandboxPolicy` during `turn/start`.
- Existing Settings structured workflow form and import/export path.

## Handoff Notes

This issue surfaced because a run could update Linear but could not perform the required push across
SSH, SSH-over-443, HTTPS proxy, direct HTTPS, `gh`, or MCP publishing resources. The visible UI let
the operator edit `thread_sandbox`, but not the turn-level policy that controls network/file access
for the actual Codex turn. Treat this as a settings completeness and operator clarity issue.
