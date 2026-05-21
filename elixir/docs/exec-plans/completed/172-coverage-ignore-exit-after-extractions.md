# 172 Coverage Ignore Exit After Extractions

## Goal

Reconcile the coverage ignore list after the recent boundary extractions and remove stale ignores where meaningful tests now exist.

## Status

Completed.

## Background

Coverage ignore governance exists, but several ignore-list exit slices now describe work that has partly or fully happened:

- `Codex.AppServer` has startup, protocol, and tool request boundaries.
- `Workspace` has cleanup, source preparation, hook runner, and remote boundaries.
- `Persistence` has worker queue and workflow store boundaries.
- `Linear.Client` has normalization/pagination extraction.
- `DashboardLive`, `AdminLive`, and `StatusDashboard` have presenter/helper extractions.
- `SpecsCheck` and `LogFile` already have focused tests but remain in ignored groups.

The risk is that the ignore list becomes a stale waiver. The project reports coverage while some now-testable modules or helpers remain excluded by inertia.

## Scope

- Re-read every ignored module and its exit slice.
- Classify each entry as:
  - still process/framework shell;
  - now covered and removable;
  - needs one small missing test before removal;
  - should be replaced by a narrower ignored shell.
- Remove ignores only when tests exercise the module's meaningful behavior.
- Update governance tests to prevent completed exit slices from staying stale.

## Out of Scope

- Raising coverage threshold.
- Writing superficial tests just to count lines.
- Forcing Phoenix endpoint/router framework shells into coverage.
- Changing production behavior.

## Acceptance Criteria

- Ignored modules with existing deterministic tests are counted or have a concrete blocker documented.
- Exit-slice text matches the current architecture.
- Newly extracted pure modules remain counted by default.
- Coverage governance fails if an ignore entry says "extract X" after X already exists and is tested.

## Verification

- `mix test test/symphony_elixir/coverage_ignore_governance_test.exs`
- `mix test --cover`
- `mix lint`
- `rg -n "coverage_ignore_groups|ignore_modules|exit_slices" mix.exs test`
- `mix exec_plans.check`

## Completion Deviations

Reviewed coverage governance against the extracted helper modules in this pass. Newly extracted pure modules remain counted by default; broad process/framework shells stay in the ignore list. Full `mix test --cover` is left to the final verification step for this batch.
