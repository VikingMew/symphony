# 149 - Config Schema Workflow Contract Boundary

Status: Completed

## Problem

`SymphonyElixir.Config.Schema` contains embedded Ecto schemas, parsing/finalization, default workflow/profile construction, workflow contract validation, state/profile reference validation, path/env resolution, and error formatting in one large module.

The workflow contract validation block is a coherent pure responsibility. It validates states, profiles, executors, allowed updates, transitions, Linear state references, and tracker state names. Keeping it inside the schema module makes the schema module a validation monolith.

## Goal

Extract workflow/profile contract validation into a focused module such as `SymphonyElixir.Config.WorkflowContract`.

`Config.Schema` should still own the top-level schema and parse entry point, but delegate workflow policy validation to a pure validator.

## Plan

1. Inventory validation helpers from `validate_workflow_contract/1` through transition/profile/reference validation.
2. Define a pure API that accepts normalized workflow, profiles, and tracker data and returns a list of validation errors.
3. Move workflow contract helpers into the new module with direct tests.
4. Keep error wording compatible unless tests intentionally document clearer messages.
5. Replace private helpers in `Config.Schema` with a delegation call.
6. Ensure dynamic atom and string-key normalization rules remain unchanged.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/config/workflow_contract_test.exs test/symphony_elixir/workspace_and_config_test.exs`
  - Result: `65 tests, 0 failures`.
- `rg -n "validate_workflow_contract|workflow_policy_errors|validate_state_policy|profile_policy_errors|validate_transitions|workflow_known_states" lib test`
  - Result: `Config.Schema` keeps only the changeset-level delegation; workflow/profile contract helpers now live in `Config.WorkflowContract`.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

`validate_workflow_contract/1` remains as the private changeset adapter in `Config.Schema` so Ecto errors still attach to `:workflow` and `:profiles`; pure policy validation moved to `Config.WorkflowContract`.
