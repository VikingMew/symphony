# 129 Rate Limit Observability Fallback

## Goal

Make the dashboard `Rate limits` section useful even when Codex has not emitted a parseable upstream rate-limit snapshot.

The page should explain what is known, what is missing, and what evidence Symphony has observed, instead of showing only `n/a`.

## Status

Active.

## Background

The dashboard currently renders:

```text
Rate limits
Latest upstream rate-limit snapshot, when available.

n/a
```

This is technically accurate when `@payload.rate_limits` is `nil`, but it is not operationally useful. Users cannot tell whether:

- Codex never emitted rate-limit data;
- Symphony failed to parse a rate-limit event;
- no Codex updates have been received yet;
- Codex is authenticated but does not expose rate-limit information in the current mode;
- the dashboard is broken.

The current data path only updates `codex_rate_limits` when `SymphonyElixir.Orchestrator.extract_rate_limits/1` finds a recognized rate-limit shape inside a Codex update. If no such payload arrives, the presenter passes `nil` through to the LiveView and the UI prints `n/a`.

Real rate-limit values must not be invented. If upstream Codex does not provide a snapshot, Symphony should show an honest fallback with adjacent observability data: last Codex event, last update time, token totals, authentication/account update hints when available, and whether rate-limit-like events were received but not recognized.

## Scope

- Replace the bare `n/a` dashboard rendering with a structured rate-limit status panel.
- Preserve the existing raw snapshot display when a parseable rate-limit map exists.
- When no snapshot exists, show a clear fallback state such as `No upstream rate-limit snapshot received yet`.
- Surface adjacent evidence that already exists or can be safely derived:
  - last Codex event type;
  - last Codex update timestamp;
  - current token totals;
  - current active/running session count;
  - account/auth update information when Codex emits it;
  - whether a rate-limit update event was seen but could not be parsed.
- Add a small presenter boundary so the LiveView does not need to infer rate-limit state directly from raw maps.
- Keep the copy precise: distinguish `not received`, `received but unrecognized`, and `received and parsed`.
- Add tests for nil, parsed, and unrecognized rate-limit states.

## Out of Scope

- Do not fabricate real rate-limit quotas when Codex has not reported them.
- Do not call external APIs to fetch account limits.
- Do not change Codex authentication behavior.
- Do not store sensitive account credentials or tokens.
- Do not redesign the whole dashboard.
- Do not replace token accounting with rate-limit accounting.

## Acceptance Criteria

- When `snapshot.rate_limits` is present and parseable, the dashboard still shows the upstream snapshot.
- When `snapshot.rate_limits` is nil, the dashboard no longer shows only `n/a`.
- The nil state explains that no upstream rate-limit snapshot has been received.
- The nil state includes at least one useful observable fallback when available, such as token totals or last Codex event/time.
- If Symphony sees a Codex `account/rateLimits/updated` event but cannot parse the payload shape, the dashboard states that a rate-limit event was received but not recognized.
- The UI does not imply that unknown limits are zero.
- Tests cover presenter output and rendered dashboard text.

## Test Cases

- Snapshot with parsed rate limits:
  - input contains a rate-limit map;
  - presenter marks state as `available`;
  - dashboard renders the snapshot.
- Snapshot with nil rate limits and no Codex activity:
  - presenter marks state as `unavailable`;
  - dashboard renders `No upstream rate-limit snapshot received yet`.
- Snapshot with nil rate limits but token totals:
  - dashboard shows token totals as fallback context.
- Snapshot with nil rate limits but recent Codex event:
  - dashboard shows last event and timestamp as fallback context.
- Unrecognized rate-limit update event:
  - orchestrator or presenter records that a rate-limit update was observed but not parsed;
  - dashboard renders a distinct `received but unrecognized` state.
- Existing dashboard and presenter tests continue to pass.

## Implementation Notes

Prefer a small presentation structure, for example:

```elixir
%{
  status: :available | :not_received | :unrecognized,
  snapshot: map() | nil,
  last_codex_event: atom() | String.t() | nil,
  last_codex_timestamp: DateTime.t() | nil,
  token_totals: map(),
  note: String.t()
}
```

Possible implementation points:

- `SymphonyElixir.Orchestrator` already stores `codex_rate_limits` and token totals.
- `SymphonyElixirWeb.Presenter.state_payload/2` can shape a dashboard-safe rate-limit payload.
- `SymphonyElixirWeb.DashboardLive` should render the shaped payload rather than `pretty_value(@payload.rate_limits)` alone.
- `SymphonyElixir.StatusDashboard.humanize_codex_message/1` already knows about `account/rateLimits/updated`; keep terminology aligned with that output.

If the system does not currently retain the last Codex event globally, add only the minimum state needed for operator evidence. Avoid storing full raw Codex messages solely for this panel.

## Verification

- `mise exec -- mix format`
- Focused presenter/dashboard tests for rate-limit states.
- Focused orchestrator test for unrecognized rate-limit update observation if new state is added there.
- Browser or LiveView rendered evidence showing:
  - parsed snapshot state;
  - no-snapshot fallback state;
  - unrecognized-event state.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

None yet.

## Dependencies

- Existing dashboard `Rate limits` section.
- Existing orchestrator `codex_rate_limits` extraction.
- Existing token accounting surfaced on the dashboard.
- Active plan 127 if it changes the Codex update boundary.
- Active plan 118 if run-detail Codex payload persistence affects reuse of rate-limit event evidence.

## Handoff Notes

The goal is not to guarantee that rate limits are always available. The goal is to make absence diagnosable. When upstream Codex does not provide rate-limit data, the UI should say that directly and show what Symphony did observe.
