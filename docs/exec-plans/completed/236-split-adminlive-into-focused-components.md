# 236 Split AdminLive into focused components

## Goal

Break the 2172-line AdminLive monolith into per-page LiveComponents/LiveViews with a thin nav/shared-context shell.

## Status

Completed.

## Background

Source: Codex static-analysis report (codex-cli 0.147.0, read-only; 20 findings across
lib/). This plan addresses: Bad smell [3] (medium): lib/symphony_elixir_web/live/admin_live.ex (2172 lines; single render ~950).

AdminLive handles multi-page UI, import confirmation, project save, workflow validation, run history, and operator controls in one module: one ~950-line render, ~300 lines of event handling, ~500 lines of data/form helpers sharing assigns. Any settings-page change requires understanding the whole LiveView state machine.

## Scope

- Split into: Projects, Workflow, Agents, Runtime, Import components (LiveComponent or child LiveView), plus a thin shell owning navigation + shared context (projects list, auth).
- Preserve existing routes/URLs and behavior exactly (UI identical).
- Move shared data/form helpers with their components.

## Out of Scope

- UI redesign; route changes; touching behavior beyond extraction.

## Acceptance Criteria

- Each settings page lives in its own module; shell is thin.
- All admin/settings routes behave identically (existing tests + manual UI check).
- No module in the split exceeds a reasonable size (~<500 lines).

## Test Cases

- Existing web_fake_persistence_test / auth_persistence_web_test suites (they drive settings pages).
- Manual smoke: each settings tab renders and saves.

## Implementation Notes

Pure extraction — no behavior change allowed. Prefer LiveComponent with `send`/`call` boundaries matching current assigns flow.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 22 [R] + 1 [D], none in the extracted modules)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 684 tests, 2 failures (full suite). Both failures are the pre-existing
  WorkflowStoreTest concurrency race already documented in plans 233/235 (identical to the plan-232
  control run); the CoreTest persistence race did not trigger this run. No new failures. All
  admin/settings route tests (web_fake_persistence_test, auth_persistence_web_test,
  settings_import_fake_persistence_test, observability_fake_persistence_test) pass.
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (admin_live.ex shrinks 2172 -> 170 lines; 14 new
  modules under live/admin_live/; no routes touched)

## Completion Deviations

- Split shape: `admin_live.ex` is a 170-line thin shell (mount/refresh delegation + nav); page
  modules live under `lib/symphony_elixir_web/live/admin_live/`:
  settings/projects.ex (222), settings/workflow.ex (351), settings/agents.ex (238),
  settings/runtime.ex (30), settings/import.ex (211), settings/workflow_discovery.ex (120),
  workflow_state.ex (321, shared form/validation state), settings_shell.ex (210, settings nav +
  shared settings context), runs.ex (76), run_detail.ex (151), issue_detail.ex (59), events.ex (165),
  state.ex (110, shared assigns/persistence plumbing). Largest module 351 lines — under the ~500
  acceptance cap.
- The plan's "Projects/Workflow/Agents/Runtime/Import components" map to the `settings/*` modules;
  the observability surface (runs/run_detail/issue_detail/events) was extracted alongside since the
  monolith carried both. `SettingsLive` remains the unchanged route boundary forwarding to the
  AdminLive shell; all `/settings*` and `/runs*` routes behave identically (existing suites green).
- Pure extraction: no behavior change; event handler logic moved with its page. Test baseline stays
  684; no assertions changed.
- Codex iterated twice inside the sandbox (route-focused validation after a governance fix, then the
  full five-command sequence); final gates green.

## Dependencies

None.

## Handoff Notes

Executed by Codex CLI in a clean worktree (`--sandbox workspace-write`). Prompt must
carry: file whitelist, environment-noise rules (Mix.PubSub/port/socket errors in sandbox
are noise — continue), forbid touching docs/exec-plans and design docs, forbid adding
`.dialyzer_ignore.exs` entries, forbid custom build environments (`_build/codex_*`),
report format (Completed / Validation / Deviations / Blockers). Reviewer runs the full
gate sequence outside the sandbox, reviews the diff for behavior equivalence, archives
this plan, and commits.
