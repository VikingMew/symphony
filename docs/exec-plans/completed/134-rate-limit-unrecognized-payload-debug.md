# 134 Rate Limit Unrecognized Payload Debug

## Goal

When Symphony receives a Codex rate-limit update but cannot recognize the payload shape, the dashboard should expose a safe, bounded raw payload view so operators and developers can see the actual upstream data needed to fix the parser.

## Status

Completed.

## Background

Active plan 129 adds a structured `Rate limits` dashboard state that can distinguish:

- parsed snapshot available;
- no snapshot received;
- rate-limit update received but unrecognized.

A real dashboard state now shows:

```text
A Codex rate-limit update was received, but Symphony did not recognize its payload shape.

unrecognized

Token totals
Total 85,134 · In 84,005 · Out 1,129

Codex evidence
Last event notification
item started: reasoning (rs_035d9d8d7)
2026-05-21T03:43:30.848964Z
```

This is better than `n/a`, but it still does not provide enough evidence to repair the parser. If Symphony knows a rate-limit-like event was received, it should show the scrubbed raw payload or candidate payload path that failed recognition. Otherwise developers cannot see the upstream shape without attaching logs or adding temporary instrumentation.

The debug view must be safe by default: bounded, scrubbed, and collapsed until explicitly expanded.

## Scope

- Extend the unrecognized rate-limit state with raw debug context.
- Capture enough data when a rate-limit-like update is observed but parsing fails:
  - source path, for example `update.payload`, `update.raw`, or `params.msg.payload`;
  - event/method name if available;
  - bounded raw candidate payload;
  - recognition failure reason if available.
- Render a collapsed `Raw rate-limit payload` section in the dashboard only for unrecognized states.
- Scrub sensitive fields before display:
  - tokens;
  - Authorization headers;
  - cookies;
  - secrets;
  - credentials;
  - API keys.
- Bound the displayed payload size.
- Preserve enough structure to make parser updates straightforward.
- Add tests proving raw debug payload is visible only in unrecognized state and is scrubbed.

## Out of Scope

- Do not display unsanitized raw Codex messages.
- Do not expose full unbounded JSON-RPC transcripts.
- Do not call external APIs to fetch rate limits.
- Do not change Codex authentication behavior.
- Do not treat unknown limits as zero.
- Do not solve all future payload-shape variants in this plan unless a tested shape is already visible.

## Acceptance Criteria

- In `unrecognized` rate-limit state, the dashboard renders a collapsed `Raw rate-limit payload` details section.
- Expanding the section shows a bounded, scrubbed raw payload or candidate payload.
- The section shows where the payload came from, such as `update.payload.params.msg.payload`.
- Sensitive fields are redacted before rendering.
- The displayed payload is size-bounded.
- Parsed/available rate-limit state does not show the unrecognized raw debug section.
- Not-received state does not show the unrecognized raw debug section.
- Tests cover scrubbing, bounding, and conditional rendering.

## Test Cases

- Unrecognized payload with secret-bearing fields:
  - dashboard renders `Raw rate-limit payload`;
  - token/authorization/cookie/secret fields are redacted.
- Unrecognized payload with nested candidate data:
  - dashboard shows candidate source path;
  - payload remains structurally readable.
- Oversized unrecognized payload:
  - dashboard truncates or bounds displayed content;
  - page remains responsive.
- Parsed rate-limit payload:
  - dashboard shows parsed snapshot;
  - raw unrecognized debug section is absent.
- No rate-limit payload:
  - dashboard shows no-snapshot fallback;
  - raw unrecognized debug section is absent.
- Presenter/unit test:
  - unrecognized summary includes debug payload metadata;
  - scrubbed output does not contain known secret values.

## Implementation Notes

This should extend the presentation shape from plan 129. For example:

```elixir
%{
  status: :unrecognized,
  note: "...",
  debug_payload: %{
    source_path: "update.payload.params.msg.payload",
    method: "account/rateLimits/updated",
    payload: scrubbed_bounded_map,
    truncated: boolean()
  }
}
```

The parser should not store every raw Codex update. It should retain only the candidate payload for rate-limit-like events that could not be parsed.

Rate-limit-like events may include:

- `account/rateLimits/updated`;
- methods or wrapper events containing `rateLimits`;
- payloads with keys such as `rate_limits`, `rateLimits`, `primary`, `secondary`, `credits`, or related limit metadata.

Reuse existing scrub/bound helpers where possible. If current scrub helpers only live inside a LiveView, move the safe generic portion to a shared helper so presenter tests can assert redaction without rendering templates.

The raw debug section should use `<details>` or equivalent collapsed UI. It is for diagnosis, not the main status copy.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/event_presenter_test.exs test/symphony_elixir/dashboard_signal_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- Unit coverage verifies unrecognized debug payload source path, method, failure reason, scrubbing, and oversized string bounding.
- Dashboard LiveView coverage verifies the collapsed `Raw rate-limit payload` section appears for unrecognized updates and remains absent for parsed snapshots.
- Existing dashboard rate-limit coverage from plan 129 remained in `test/symphony_elixir/dashboard_signal_test.exs`.
- `mise exec -- mix test --cover` passed with 432 tests, 0 failures, 2 skipped, 85.75% total coverage.
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

The orchestrator stores only the bounded candidate debug payload in the unrecognized observation, not the full upstream update. This preserves parser repair evidence without retaining unbounded Codex transport transcripts.

## Dependencies

- Active plan 129 for the dashboard rate-limit observability fallback.
- Active plan 127 if it changes the Codex update boundary.
- Existing dashboard bounded/scrubbed payload rendering patterns.

## Handoff Notes

The purpose of this plan is to make parser failures actionable. If the system says it received a rate-limit update but could not parse it, the UI must show enough safe raw evidence for a developer to add the missing payload shape.
