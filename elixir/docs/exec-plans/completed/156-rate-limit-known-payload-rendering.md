# 156 Rate Limit Known Payload Rendering

## Goal

Teach Symphony to recognize and render the observed Codex rate-limit payload shape instead of classifying it as `unrecognized`.

When Codex provides `limitId`, `planType`, `primary.usedPercent`, `primary.windowDurationMins`, `primary.resetsAt`, `secondary.usedPercent`, `secondary.windowDurationMins`, and `secondary.resetsAt`, the dashboard should show a normal parsed rate-limit snapshot with useful reset timing and plan context.

## Status

Completed.

## Background

Plans 129 and 134 made rate-limit absence and parser failures diagnosable. The dashboard can now show an `unrecognized` state and reveal a scrubbed raw payload. A real raw payload now shows:

```elixir
%{
  "credits" => nil,
  "limitId" => "codex",
  "limitName" => nil,
  "planType" => "pro",
  "primary" => %{
    "resetsAt" => 1779341757,
    "usedPercent" => 65,
    "windowDurationMins" => 300
  },
  "rateLimitReachedType" => nil,
  "secondary" => %{
    "resetsAt" => 1779848319,
    "usedPercent" => 18,
    "windowDurationMins" => 10080
  }
}
```

This is clearly a valid rate-limit snapshot. Symphony currently fails to recognize it because the parser expects snake_case fields such as `limit_id`, while the observed Codex payload uses camelCase fields such as `limitId`.

The UI already has enough raw evidence to fix the parser. The next step is to normalize this known shape and display it as parsed data rather than leaving it in the debug fallback.

## Scope

- Extend rate-limit parsing to accept the observed camelCase Codex payload shape:
  - `limitId`;
  - `limitName`;
  - `planType`;
  - `rateLimitReachedType`;
  - `primary.usedPercent`;
  - `primary.windowDurationMins`;
  - `primary.resetsAt`;
  - `secondary.usedPercent`;
  - `secondary.windowDurationMins`;
  - `secondary.resetsAt`;
  - `credits`.
- Normalize accepted payloads into one internal rate-limit shape used by dashboard presenters.
- Render a parsed dashboard state instead of `unrecognized` for this payload.
- Show useful operator-facing fields:
  - plan type, for example `pro`;
  - limit id, for example `codex`;
  - primary usage percent and window duration;
  - secondary usage percent and window duration;
  - reset times as readable timestamps or relative durations;
  - reached type when present.
- Keep raw debug payload available only as optional details, not as the main state, once the payload is recognized.
- Add tests using the exact observed payload shape.

## Out of Scope

- Do not invent remaining quota counts when Codex only provides used percentages.
- Do not call external APIs to enrich the snapshot.
- Do not expose unsanitized raw payloads.
- Do not remove the unrecognized fallback; future unknown shapes should still be debuggable.
- Do not redesign the whole dashboard rate-limit card beyond what is needed to display parsed data clearly.

## Acceptance Criteria

- The observed `limitId`/`usedPercent` payload is classified as a parsed rate-limit snapshot.
- Dashboard no longer shows `unrecognized` for that shape.
- Dashboard shows plan type and limit id when present.
- Dashboard shows primary and secondary usage percentages.
- Dashboard shows primary and secondary window durations in a readable form.
- Dashboard shows reset timestamps or relative reset text when `resetsAt` is present.
- The parser remains compatible with existing snake_case shapes.
- Unknown future shapes still fall back to the unrecognized debug panel.

## Test Cases

- Observed camelCase payload:
  - parser returns parsed rate-limit snapshot;
  - dashboard renders `pro`, `codex`, primary `65%`, secondary `18%`;
  - dashboard does not render the main status as `unrecognized`.
- Snake_case legacy payload:
  - parser behavior remains unchanged.
- Payload with only primary bucket:
  - dashboard renders primary data and omits secondary cleanly.
- Payload with `rateLimitReachedType` present:
  - dashboard surfaces reached type as warning/error context.
- Payload with nil `credits`:
  - dashboard does not crash and does not show misleading credit data.
- Unknown payload:
  - unrecognized debug fallback still appears.

## Implementation Notes

Prefer a normalization boundary before presentation. Do not scatter camelCase handling across templates.

Potential normalized shape:

```elixir
%{
  limit_id: "codex",
  limit_name: nil,
  plan_type: "pro",
  rate_limit_reached_type: nil,
  primary: %{
    used_percent: 65,
    window_duration_mins: 300,
    resets_at: 1779341757
  },
  secondary: %{
    used_percent: 18,
    window_duration_mins: 10080,
    resets_at: 1779848319
  },
  credits: nil
}
```

Relevant implementation areas are likely:

- the orchestrator rate-limit extraction function;
- the dashboard presenter rate-limit summary;
- the dashboard LiveView rate-limit card;
- the Codex message humanizer that renders `account/rateLimits/updated`.

Keep the parser permissive about string vs atom keys, but avoid dynamic atom creation.

`resetsAt` appears to be a Unix timestamp. Confirm units in tests using a fixed value. If unit ambiguity exists, render the raw timestamp plus a best-effort formatted time rather than silently producing a wrong date.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/codex_update_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir_web/dashboard_presenter_test.exs test/symphony_elixir/extensions_test.exs` - 35 tests, 0 failures
- `rg -n "limitId|usedPercent|windowDurationMins|resetsAt|rate_limit_reached_type|rateLimitReachedType|rate_limit_bucket|rate_limit_plan|RateLimitParser" lib test`
- `git diff --check`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- The rendered LiveView evidence is the `dashboard renders observed parsed codex rate-limit payload` test in `extensions_test.exs`; no browser screenshot was needed because the dashboard has existing rendered LiveView coverage.

## Dependencies

- Completed plan 129 for rate-limit observability fallback.
- Completed plan 134 for unrecognized payload debug output.
- Existing dashboard rate-limit card and Codex update processing.

## Handoff Notes

This plan converts an observed "unknown shape" into a supported shape. Keep the debug fallback for future unknown payloads, but the payload documented here should become normal parsed dashboard data.
