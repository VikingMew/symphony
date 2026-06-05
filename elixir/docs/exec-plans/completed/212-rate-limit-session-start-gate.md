# 212 Rate Limit Session Start Gate

## Goal

Prevent Symphony from starting new Codex sessions when upstream rate-limit headroom is too low, so long-running agents do not begin work shortly before the account reaches a hard stop.

Default policy:

- do not start a new session when the 5-hour window headroom is below `5%`;
- do not start a new session when the 7-day / 1-week window headroom is below `3%`;
- once a blocking window resets, wait an additional `20 minutes` before starting new sessions.

All thresholds and the post-reset wait duration must be configurable.

## Status

Completed.

## Background

Symphony now receives Codex rate-limit updates that include primary and secondary windows. The known payload shape contains fields such as:

- `primary.usedPercent`;
- `primary.windowDurationMins`;
- `primary.resetsAt`;
- `secondary.usedPercent`;
- `secondary.windowDurationMins`;
- `secondary.resetsAt`.

For the observed Codex payload, `primary.windowDurationMins == 300` represents the 5-hour window and `secondary.windowDurationMins == 10080` represents the 7-day / 1-week window. UI labels or configuration aliases may call that second window `7d` or `1w`; both names must map to the same 10080-minute policy.

Today the rate-limit information is mostly observational. The orchestrator can still start new sessions even when the account is close to exhaustion. That creates a predictable failure mode: a session begins, spends workspace/setup time, then gets interrupted by upstream limits before it can finish useful work.

The scheduler should treat low rate-limit headroom as a dispatch gate, similar in spirit to disk-space spawn protection. Existing running sessions should not be killed by this policy; the gate should only prevent new session starts.

## Scope

- Add a configurable session-start gate based on the latest recognized Codex rate-limit snapshot.
- Support independent policies for:
  - 5-hour window, default block threshold `5%` remaining;
  - 7-day / 1-week window, default block threshold `3%` remaining.
- Interpret `usedPercent` as consumed capacity and derive remaining headroom as `100 - usedPercent`.
- Match windows by duration rather than display label:
  - `300` minutes maps to the 5-hour window;
  - `10080` minutes maps to the 7-day / 1-week window.
- Treat `7d` and `1w` as equivalent labels/aliases for the 10080-minute window in settings and display.
- If either configured window is below its threshold, block creation of new Codex sessions.
- When a blocking window has a `resetsAt` value, do not resume immediately at reset time. Resume only after `resetsAt + post_reset_delay`, default `20 minutes`.
- Handle time zones correctly:
  - treat upstream `resetsAt` epoch values as absolute UTC instants;
  - compare using UTC internally;
  - display local time using the operator/browser timezone where the UI already does that, or clearly label UTC otherwise;
  - do not compare formatted local strings.
- Make thresholds configurable from persistent settings, with environment/default fallback if that is the project's current settings pattern.
- Make the gate visible to operators:
  - Dashboard should show that dispatch is paused by rate-limit gate;
  - include which window blocked start, remaining percent, reset time, post-reset resume time, and current configured threshold;
  - queued work should remain queued rather than silently disappearing.
- Apply the gate to all paths that start a new Codex session:
  - issue-backed runs;
  - refinement-only runs;
  - operator runs such as `nap` and `day_dreaming` once they use a real executor.
- Persist an event when a start is blocked by the rate-limit gate, but avoid flooding events on every scheduler tick.

## Out of Scope

- Stopping already running sessions when rate-limit headroom falls below the threshold.
- Predicting token usage for a specific task.
- Changing Codex upstream rate-limit semantics.
- Adding per-profile token budgeting.
- Replacing the existing rate-limit display page.
- Treating unrecognized rate-limit payloads as hard blockers.

## Acceptance Criteria

- With a latest 5-hour snapshot showing less than `5%` remaining, Symphony does not start a new Codex session.
- With a latest 7-day / 1-week snapshot showing less than `3%` remaining, Symphony does not start a new Codex session.
- With both windows above threshold, normal dispatch remains unchanged.
- When blocked, queued work stays queued and the Dashboard clearly says dispatch is paused by rate-limit headroom.
- If the 5-hour window reset is at `T`, new session starts remain blocked until at least `T + 20 minutes` by default.
- If the 7-day / 1-week window reset is at `T`, new session starts remain blocked until at least `T + 20 minutes` by default.
- The post-reset delay and both percent thresholds can be changed without code edits.
- Internal time comparisons use UTC instants or epoch seconds and are independent of server/browser timezone.
- UI display of reset/resume times is readable and not misleading across time zones.
- Existing running sessions are not force-stopped by this gate.
- Missing or unrecognized rate-limit snapshots do not block dispatch by default, but the UI states that no enforceable snapshot is available.

## Test Cases

- Policy unit test:
  - primary window duration `300`, `usedPercent: 96`;
  - default remaining threshold is `5%`;
  - assert new session start is blocked.
- Policy unit test:
  - secondary window duration `10080`, `usedPercent: 98`;
  - default remaining threshold is `3%`;
  - assert new session start is blocked.
- Boundary test:
  - 5-hour remaining is exactly `5%`;
  - assert behavior matches the documented comparison, preferably allow start at threshold and block only below threshold.
- Boundary test:
  - 7-day / 1-week remaining is exactly `3%`;
  - assert behavior matches the documented comparison.
- Alias test:
  - configure the long window threshold using `7d`;
  - configure the same policy using `1w`;
  - assert both apply to snapshots with `windowDurationMins: 10080` and produce the same gate decision.
- Reset-delay test:
  - blocking snapshot reset time is now plus one minute;
  - assert dispatch is blocked before reset and still blocked until reset plus configured delay.
- Timezone test:
  - server timezone and displayed/browser timezone differ;
  - assert policy compares UTC instants and produces the same gate decision.
- Missing snapshot test:
  - no recognized rate-limit snapshot exists;
  - assert dispatch is allowed by default and Dashboard shows unknown/unavailable enforcement state.
- Stale snapshot test:
  - latest snapshot is older than a configured staleness limit if such a limit is introduced;
  - assert documented behavior is followed and visible.
- Orchestrator dispatch test:
  - an eligible issue exists;
  - rate-limit gate blocks;
  - assert no workspace or Codex session is started.
- Operator-run test:
  - request `nap`;
  - rate-limit gate blocks;
  - assert the operator task is queued/paused rather than inserted as a misleading running session.
- Event persistence test:
  - repeated scheduler ticks while blocked produce bounded events, not unbounded duplicate noise.
- Settings test:
  - change 5-hour threshold, 7-day / 1-week threshold, and post-reset delay;
  - assert policy uses saved values.

## Implementation Notes

- Introduce a small pure policy module rather than embedding comparisons throughout the orchestrator. A useful shape is:
  - input: latest rate-limit snapshot, current UTC time, settings;
  - output: `:allow` or `{:block, details}`.
- Store policy details in a structured block that can be rendered by Dashboard and used in logs/events:
  - `window`;
  - `window_duration_mins`;
  - `remaining_percent`;
  - `threshold_percent`;
  - `resets_at`;
  - `resume_after`;
  - `reason`.
- Use `DateTime.from_unix!/1` or equivalent UTC-safe conversion for upstream epoch seconds.
- Do not infer 5-hour/7-day windows by names like `primary` or `secondary` alone. Use `windowDurationMins` so the policy remains robust if upstream labels change.
- Normalize operator-facing window names before applying settings. `7d` and `1w` are equivalent aliases for the same 10080-minute window and must not create separate policies.
- Decide and document the exact threshold comparison:
  - recommended: block when `remaining_percent < threshold_percent`;
  - this means exactly `5%` or exactly `3%` is still allowed.
- Add a setting to disable the gate only if the project already supports explicit operator override settings. If added, the UI must make the risk clear.
- Keep the dispatch gate before expensive work:
  - before workspace allocation;
  - before repository update;
  - before Codex app-server session creation.
- The gate must compose with existing blockers such as disk-space guard, runtime busy state, and missing configuration. The Dashboard should surface the most actionable blocker without hiding the others.

## Verification

- `mise exec -- mix test test/symphony_elixir/codex/rate_limit_gate_test.exs test/symphony_elixir/orchestrator_operator_tasks_test.exs test/symphony_elixir/orchestrator_rate_limit_gate_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir_web/dashboard_presenter_test.exs test/symphony_elixir/workflow_form_rate_limit_gate_test.exs` passed with 27 tests, 0 failures.
- `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/orchestrator_operator_tasks_test.exs test/symphony_elixir/orchestrator_rate_limit_gate_test.exs test/symphony_elixir/codex/rate_limit_gate_test.exs test/symphony_elixir/workflow_form_rate_limit_gate_test.exs test/symphony_elixir_web/dashboard_presenter_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir_web/live/settings_fake_persistence_test.exs` passed with 112 tests, 0 failures.
- `mise exec -- mix test` passed with 636 tests, 0 failures, 2 skipped.
- `mix exec_plans.check` will be run after moving this plan into `completed/`.

## Completion Deviations

- The primary enforcement point is the orchestrator dispatch path, so issue-backed and operator work are blocked before candidate fetch, workspace allocation, repository update, or Codex app-server startup. `AgentRunner` also has a secondary guard immediately before Codex session start for direct runner calls and stale scheduler inputs.
- Dashboard reset/resume times are rendered as UTC ISO timestamps by the presenter. The policy comparisons use UTC instants and epoch seconds, so the enforcement behavior is independent of browser or server display timezone.

## Dependencies

- Completed plan 156 for recognized rate-limit payload rendering.
- Completed plan 129 for rate-limit observability fallback.
- Completed plan 134 for unrecognized rate-limit payload debug visibility.
- Completed plan 192 for the analogous spawn guard pattern around disk space.
- Active or completed operator-run work should apply this gate before starting real operator Codex sessions.

## Handoff Notes

This is a scheduler safety feature, not just a display feature. The key invariant is: low rate-limit headroom must prevent new Codex sessions from starting before workspace or Codex startup work begins.

The policy should be conservative only when it has recognized data. Unknown or unrecognized payloads should remain visible, but should not silently freeze the system unless a later setting explicitly asks for fail-closed behavior.
