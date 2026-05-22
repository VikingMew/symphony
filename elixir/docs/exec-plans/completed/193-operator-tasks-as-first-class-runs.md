# 193 Operator Tasks As First Class Runs

## Goal

Make `nap` and `day_dreaming` first-class Symphony runs that appear in Dashboard `Running sessions`, run history, run detail, session history, cancellation, and observability flows.

They are real runs even though they are not backed by an input Linear issue. The missing issue id should be a supported run shape, not a reason to keep them in a separate lightweight `operator_tasks` display model.

## Status

Completed.

## Background

Plans 184-188 introduced `Take a nap` and `Day dreaming` operator controls. The delivered implementation created an `operator_tasks` shell:

- Dashboard buttons exist.
- The runtime can show `nap: running` or `day dreaming: running`.
- The task has a generated operator run id and summary counters.

However, those tasks are not represented in `snapshot.running`. Dashboard `Running sessions` renders only `payload.running`, which comes from issue-backed orchestrator running entries. As a result, `nap` and `day_dreaming` can say `running` in Runtime controls while `Running sessions` says no active session or omits the work.

That is the wrong product model. If an operator task occupies runtime execution capacity and eventually runs Codex with a profile, it should be a normal run from the operator's perspective:

- it has a run id;
- it has a kind/profile;
- it may have a workspace;
- it may have a Codex session id;
- it has session history, token usage, failure reason, and result summary;
- it can be force-stopped;
- it should be visible wherever active runs are visible.

The only meaningful difference from Linear issue work is that the source is operator-initiated and `issue_id` / `issue_identifier` are absent.

## Scope

- Introduce a first-class operator-run model for `nap` and `day_dreaming`.
- Allow persisted `RunRecord` rows for runs without a Linear issue.
- Add explicit run kind/source fields or an equivalent durable representation:
  - `kind`: `issue`, `nap`, `day_dreaming`, or similar;
  - `profile`: `nap` or `day_dreaming` where applicable;
  - operator-visible label such as `Take a nap` or `Day dreaming`.
- Update orchestrator running state so operator runs appear in the same active-run collection used by Dashboard `Running sessions`.
- Update Dashboard `Running sessions` presentation:
  - show issue-backed runs as today;
  - show operator runs without issue id using run label/kind and run id;
  - link to run detail rather than issue JSON for operator runs.
- Update run detail/history pages to render operator runs gracefully when `issue_identifier` is nil.
- Preserve `operator_tasks` only as a control-state convenience if needed, but do not make it the only source of active execution visibility.
- Run `nap` and `day_dreaming` through the same Codex session/update/session-history persistence paths as other runs once their executor starts.
- Ensure force stop cancels active operator runs and records stopped status.
- Ensure active-session counts, rate-limit active-session counts, token totals, and runtime summaries include operator runs.
- Add tests covering active display, persistence, run detail, cancellation, and no-issue rendering.

## Out of Scope

- Changing the nap or day dreaming prompt content.
- Changing the `linear_issue_create` tool policy.
- Making operator runs concurrent with normal issue runs unless explicitly allowed elsewhere.
- Requiring a fake Linear issue for operator runs.
- Creating an operator issue in Linear merely to satisfy existing run schema.
- Adding recurring/scheduled operator runs.

## Acceptance Criteria

- Clicking `Take a nap` when idle creates a first-class run visible in Dashboard `Running sessions`.
- Clicking `Day dreaming` when idle creates a first-class run visible in Dashboard `Running sessions`.
- Running sessions does not require `issue_identifier` for operator runs.
- Operator run rows display a clear run label/kind and run id.
- Operator run rows expose session id, runtime/turns, Codex update, session history, and tokens when available.
- Operator run rows link to a run detail page, not issue JSON.
- Run detail renders for operator runs with no issue id and no issue identifier.
- Persisted run history includes completed/failed/stopped operator runs.
- Force stop all agents stops active operator runs and records `stopped`.
- Active session/rate-limit counts include operator runs while they are running.
- Existing issue-backed runs still render exactly as before.

## Test Cases

- Dashboard render with no active work:
  - click `Take a nap`;
  - assert `Running sessions` contains `Take a nap` or `nap`;
  - assert the row has a run id and no broken issue link.
- Dashboard render with no active work:
  - click `Day dreaming`;
  - assert `Running sessions` contains `Day dreaming`.
- Presenter test:
  - snapshot contains one issue-backed running entry and one operator running entry;
  - payload includes both in `running`;
  - counts.running is `2`.
- Run schema/persistence test:
  - create a run with `kind: nap` and nil issue fields;
  - changeset is valid;
  - required issue fields still remain required for issue-backed runs if that rule is retained.
- Run detail test:
  - operator run detail page displays run id, kind/profile, status, timestamps, session history, and events without issue metadata.
- Session history test:
  - operator run receives Codex update events;
  - session history renders the same readable event rows as issue-backed runs.
- Force stop test:
  - active nap run is stopped;
  - stopped run is persisted;
  - no Linear rollback is attempted because there is no issue state transition.
- Regression test:
  - issue-backed implementation run still renders issue id, state, session, tokens, and JSON/details links.

## Implementation Notes

- Current `RunRecord` validates `issue_identifier` as required. This must change for operator runs. Prefer adding explicit `kind`/`source` fields rather than overloading fake identifiers.
- If the existing `runs` table cannot support kind/profile without migration, add a migration instead of storing this only in event payloads.
- Keep the display model honest:
  - issue-backed run source: Linear issue;
  - operator run source: Dashboard operator action.
- Avoid making `operator_tasks` a parallel run store. It can track button state or pending queued intent, but active execution should live in the same run/running state as all other active work.
- The orchestrator should probably create a synthetic running entry shape for operator runs with:
  - `run_id`;
  - `kind`;
  - `profile`;
  - `identifier: nil`;
  - `issue: nil`;
  - `state: "nap"` / `"day_dreaming"` or a separate display state;
  - normal session/token/history fields.
- Presenter and Dashboard should not assume every running entry has `issue_identifier`, `issue_id`, or a Linear state.
- Prefer a run-detail link for all rows. Issue-specific JSON can become a secondary link only when issue metadata exists.
- Force-stop rollback logic must skip Linear rollback for operator runs because there is no Symphony-owned Linear state transition.
- Update rate-limit status `active_sessions` to count all active run entries, including operator runs.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/dashboard_signal_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex_update_test.exs`
- `mise exec -- mix exec_plans.check`
- Browser verification of Dashboard:
  - `Take a nap` appears in `Running sessions` while active;
  - row has no broken issue link;
  - force stop removes/stops the row;
  - completed operator run is visible from run history/detail.

## Completion Deviations

None.

## Dependencies

- Completed plan 184 for Dashboard nap/day dreaming controls and queue shell.
- Completed plan 185 for `nap` profile.
- Completed plan 186 for restricted issue creation tool.
- Completed plan 187 for nap result summary semantics.
- Completed plan 188 for day dreaming product discovery control/profile intent.
- Completed plan 062 for run detail observability pages.
- Completed plan 116 for readable run detail session history.
- Completed plan 141 for run detail agent execution summary.
- Completed plan 192 for pre-spawn workspace disk guard, which should apply equally to operator runs.

## Handoff Notes

Treat this as a product model correction, not a cosmetic Dashboard tweak. `nap` and `day_dreaming` are operator-initiated runs without issue ids. They should share the same run/session observability path as issue-backed work so operators can answer: what is running, what did it do, what commands/events happened, what failed, and where is the final result?

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

