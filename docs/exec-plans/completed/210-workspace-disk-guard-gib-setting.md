# 210 Workspace Disk Guard GiB Setting

## Goal

Change the workspace disk guard setting from an operator-facing `Minimum free bytes` field to a human-scale GiB/GB field.

Operators should enter values like `1`, `2.5`, or `10` GiB instead of raw byte counts like `1073741824`.

## Status

Completed.

## Background

Completed plan 192 added a workspace disk-space guard. The implementation exposes the threshold in Settings as:

- label: `Minimum free bytes`;
- input value: raw bytes;
- default: `1073741824`;
- internal config key: `workspace.min_free_bytes`.

The runtime behavior is correct, but the Settings UX is not. Raw bytes are hard to read and easy to mistype. The product intent was "1G/1GiB free space," not "make the operator type a ten-digit integer."

The runtime can continue storing bytes internally. The operator-facing form should use GiB or GB and convert at the form boundary.

## Scope

- Replace the Settings label `Minimum free bytes` with an operator-facing label such as `Minimum free GiB`.
- Display the current configured byte threshold as a GiB value in the form.
- Accept decimal values such as `0`, `0.5`, `1`, `2.5`, and `10`.
- Convert the form value to integer bytes when saving workflow settings.
- Preserve the runtime config shape if keeping `workspace.min_free_bytes` is simpler and less disruptive.
- Update validation messages to mention GiB/GB, not bytes.
- Update disk guard logs/operator messages so the setting name points to `Minimum free GiB` or equivalent.
- Keep default behavior equivalent to `1 GiB = 1_073_741_824 bytes`.
- Add tests for display conversion, save conversion, validation, and runtime guard compatibility.

## Out of Scope

- Changing disk guard runtime semantics.
- Implementing automatic workspace deletion.
- Changing the stored config key unless necessary.
- Adding unit selector controls for MB/GB/TB.
- Changing unrelated workspace settings.

## Acceptance Criteria

- Settings no longer asks users to type raw byte counts for the minimum free-space threshold.
- Default display value is `1` or `1.0` GiB, not `1073741824`.
- Saving `2` GiB stores `2_147_483_648` bytes or an equivalent internal representation that runtime consumes correctly.
- Saving `0.5` GiB stores `536_870_912` bytes.
- Saving `0` disables the guard as before.
- Invalid values show an error that names GiB/GB.
- Existing workflows with `workspace.min_free_bytes` still load and display correctly.
- Existing runtime guard tests still pass.

## Test Cases

- `WorkflowForm.from_settings` or equivalent:
  - `workspace.min_free_bytes = 1_073_741_824`;
  - form displays `1` or `1.0`.
- Save draft:
  - `workspace_min_free_gib = "2"`;
  - resulting config has `workspace.min_free_bytes = 2_147_483_648`.
- Save draft:
  - `workspace_min_free_gib = "0.5"`;
  - resulting config has `workspace.min_free_bytes = 536_870_912`.
- Save draft:
  - blank or non-number value;
  - validation error says `Minimum free GiB`.
- Render Settings page:
  - label says `Minimum free GiB` or `Minimum free space (GiB)`;
  - raw `1073741824` is not visible.
- Runtime disk guard:
  - consumes the stored byte value unchanged.
- Operator message:
  - low disk event refers to the new setting label.

## Implementation Notes

- Prefer keeping `workspace.min_free_bytes` as the canonical runtime config key for now. That avoids a schema/storage migration and keeps `WorkspaceDiskGuard` simple.
- Add a form-only field such as `workspace_min_free_gib`.
- Conversion should use binary GiB unless the UI explicitly says GB:
  - `1 GiB = 1_073_741_824 bytes`.
- If product copy uses `GB`, decide whether it means decimal `1_000_000_000` or keep binary semantics and label it `GiB`. For precision, `GiB` is preferred.
- Decimal parsing should avoid floating-point surprises where practical. Parse as decimal text and multiply with enough precision, then round or floor consistently.
- Existing imported YAML may still contain `min_free_bytes`; display conversion must handle it.
- Export can continue writing bytes unless a separate plan changes package format.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workflow_form_disk_guard_test.exs test/symphony_elixir/workspace_disk_guard_test.exs test/symphony_elixir_web/live/settings_fake_persistence_test.exs`
- `mise exec -- mix test --cover`
  - Result: 620 tests, 0 failures, 2 skipped.
- `mise exec -- mix exec_plans.check`
- Rendered Settings assertions confirm the form label/name use `Minimum free GiB` / `workspace_min_free_gib` and raw `1073741824` is not shown.

## Completion Deviations

None.

## Dependencies

- Completed plan 192 for workspace disk-space spawn guard.

## Handoff Notes

This is a form boundary fix. Keep bytes as the runtime unit if that keeps the guard precise, but never make operators type or visually parse raw bytes in Settings.
