# 137 - Approval Policy Doc Runtime Drift

Status: Completed

## Problem

The public README still describes the legacy object-form Codex approval policy, including the old `reject` map shape, as a compatibility path that should not be used in new packages. The runtime schema has moved further: non-empty approval policy maps are rejected and only an empty map is normalized to `"never"`.

This creates a documentation/runtime contract mismatch:

- `README.md` still mentions legacy object-form `reject` policy normalization.
- `lib/symphony_elixir/config/schema.ex` rejects non-empty approval policy maps.
- `test/symphony_elixir/workspace_and_config_test.exs` includes coverage that legacy maps are rejected.
- User-facing package guidance elsewhere says the old `reject` map is not public workflow package syntax.

The result is a bad smell: new contributors can follow a long-term document and write configuration that the parser now rejects.

## Goal

Make the approval policy contract single-source and explicit:

- Public workflow package docs must describe only the currently accepted shape.
- If any legacy import compatibility remains, document it as an internal/import boundary only, not package authoring syntax.
- Tests should lock the intended boundary without requiring readers to infer policy from a rejection test alone.

## Plan

1. Audit all references to `approval_policy`, `reject`, and legacy Codex approval maps in README, user guides, workflow package docs, examples, and tests.
2. Decide the contract in code terms:
   - Either non-empty object-form maps are rejected everywhere.
   - Or legacy maps are accepted only at a named import/migration boundary and normalized before schema validation.
3. Update long-term docs so package authors see one supported representation.
4. Keep or add focused tests that prove rejected legacy maps produce a clear error message, or that import-only legacy normalization cannot leak into new package examples.
5. Remove any ambiguous phrasing that implies new packages can still write object-form approval maps.

## Verification

- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
  - `60 tests, 0 failures`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs`
  - `4 tests, 0 failures`
- `rg -n "approval_policy|reject|legacy codex|legacy.*approval" README.md docs lib test`
  - Public package authoring docs now describe only string enum values and state that legacy object-form `reject` payloads are rejected before runtime.
  - Remaining `reject` matches are code/test names, runtime startup diagnostics, prior completed plan history, or non-approval-policy uses.
- `mise exec -- mix exec_plans.check`
  - Run after README active-plan indexing was repaired.

## Completion Deviations

None.
