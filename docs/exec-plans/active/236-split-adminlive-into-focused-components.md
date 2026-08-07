# 236 Split AdminLive into focused components

## Goal

Break the 2172-line AdminLive monolith into per-page LiveComponents/LiveViews with a thin nav/shared-context shell.

## Status

Active.

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

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (664 baseline, 0 failures, 2 skipped; known flaky:
  OrchestratorStatusTest `:sys.get_state` timeout, HookRunnerTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

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
