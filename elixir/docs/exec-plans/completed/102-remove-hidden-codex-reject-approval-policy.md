# 102 Remove Hidden Codex Reject Approval Policy

## Goal

Fix Codex startup failures caused by the hidden legacy `approval_policy` value `%{reject: ...}`. Symphony should no longer default, persist, or send the old `reject` approval policy shape to `codex app-server`; it should use a current Codex-supported approval policy value and make the setting visible or intentionally fixed.

## Status

Completed.

## Background

A real run failed before the Codex session handshake:

```text
Invalid request: unknown variant `reject`, expected one of `untrusted`, `on-failure`, `on-request`, `granular`, `never`
```

The operator did not configure `reject` in `workflow.yml`, and the field is not obvious in the current Settings UI. The root cause is a hidden runtime/default configuration path:

- `codex.approval_policy` can still default to the old structured map `%{"reject" => ...}` in code.
- Existing database workflow versions may also contain that old map from earlier defaults.
- Runtime is DB active workflow version first, so the user cannot fix this by editing `workflow.yml`.
- Newer `codex app-server` expects a string enum such as `never`, not the old structured `reject` variant.

This is an alpha-stage configuration bug. The fix should remove the stale hidden value rather than ask operators to understand legacy approval-policy shapes.

## Scope

- Remove the old `%{reject: ...}` default from the config schema and test helpers.
- Choose and document the product default approval policy. Use `never` unless the implementation discovers a stronger existing product decision.
- Ensure setup-required workflow drafts and empty database defaults use the current supported approval policy.
- Ensure workflow import/save validation rejects unsupported approval policy values before they can become active.
- Handle existing DB active workflow versions that contain the old `reject` map:
  - alpha-stage behavior may rewrite/repair it to the current default when loading/saving runtime config;
  - do not preserve `reject` as a long-term compatibility mode.
- Decide whether Settings / Workflow / Codex should expose approval policy as an editable field or display it as a fixed runtime value. Either way, the UI must not leave an invisible invalid value that blocks agent startup.
- Improve startup error messaging so if Codex rejects `approvalPolicy`, the message points to `Settings / Workflow / Codex / Approval policy`.
- Update docs to explain that `approval_policy` is a Codex protocol enum and list accepted values.

## Out of Scope

- Do not redesign the whole Codex sandbox model.
- Do not reintroduce the old structured `reject` approval policy.
- Do not require users to edit `workflow.yml` to fix an active DB workflow version.
- Do not add broad legacy compatibility for arbitrary old app-server protocol variants.
- Do not change lifecycle hooks or Codex pre-start command behavior; that is plan 101.

## Acceptance Criteria

- A newly created/setup-required workflow never contains `%{"reject" => ...}` under `codex.approval_policy`.
- Empty or missing `codex.approval_policy` resolves to the current supported default.
- Existing active workflow versions with `codex.approval_policy` shaped like `%{"reject" => ...}` no longer cause Codex startup failure.
- Runtime sends only a Codex-supported approval policy string to `thread/start` and `turn/start`.
- Validator rejects unsupported values such as `reject`, `%{"reject" => ...}`, or arbitrary strings not accepted by current Codex.
- Settings makes the approval policy state visible enough that operators are not blocked by an invisible value.
- Startup failures caused by `approvalPolicy` include an actionable Settings path.
- Tests that previously expected the `reject` map now expect the supported default.

## Test Cases

- Config schema defaults `codex.approval_policy` to the supported default string.
- Setup-required workflow config includes the supported default or omits the field in a way that resolves to the supported default.
- Parsing/loading a workflow with no approval policy resolves to the supported default.
- Parsing/loading a workflow with `%{"reject" => ...}` repairs or rejects it according to the chosen alpha behavior, but never sends it to Codex.
- Validation rejects `approval_policy: "reject"` and arbitrary unsupported strings.
- App server startup payload sends the supported string in `approvalPolicy` for both `thread/start` and `turn/start`.
- Live Settings UI renders the approval policy in the Codex section, either editable or clearly fixed.
- Existing DB active workflow fixture containing the old map can be loaded without causing `codex_startup_failed` due to unknown variant `reject`.

## Implementation Notes

- The field currently behaves like `StringOrMap`; this should be narrowed if no valid map shape remains for current Codex.
- Accepted current Codex values observed from the runtime error are:
  - `untrusted`
  - `on-failure`
  - `on-request`
  - `granular`
  - `never`
- Prefer a single normalization point before runtime settings are handed to `Codex.AppServer`. If old DB data is repaired there, also ensure the next save writes the repaired value.
- Because the project is alpha-stage, it is acceptable to remove old test expectations and old hidden defaults rather than support both old and new formats indefinitely.
- Keep `auto_approve_requests` aligned with the chosen default. If default remains `never`, current auto-approval behavior stays consistent.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- Focused app-server/config tests proving `approvalPolicy` is one of the supported strings.
- A regression test for old `%{"reject" => ...}` active workflow data.
- `git diff --check`

## Completion Deviations

Delivered with `never` as the product default. Existing `%{"reject" => ...}` maps are normalized to `never` during schema parsing/finalization so stale alpha database workflow versions do not keep sending the rejected protocol shape. Arbitrary maps and unsupported strings are rejected by validation.

Settings / Workflow exposes approval policy as an editable select rather than a fixed display value. The select is limited to the current Codex enum values observed from app-server: `untrusted`, `on-failure`, `on-request`, `granular`, and `never`.

Verified with:

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/core_test.exs`

## Dependencies

- Completed plan 034 for Codex sensitive env scrubbing.
- Completed plan 053 for Codex app-server startup error context.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 098 for Settings draft/save behavior.
- Active plan 101 for Codex pre-start commands is related but separate.

## Handoff Notes

This bug is not caused by the operator editing `workflow.yml`. It is caused by hidden defaults or already-saved DB workflow data using an app-server protocol shape that newer Codex rejects. The implementation should make that impossible in normal operation and should not leave the user with an invisible invalid setting.
