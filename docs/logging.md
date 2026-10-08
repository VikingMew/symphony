---
title: Logging and Error Contract
genre: spec
domain: [observability, logging]
status: current
language: en
owner: SymphonyElixir.LogFile
updated: 2026-10-08
---

# Logging and Error Contract

First-party console and rotating-file logs are JSON Lines: every physical line is one JSON object.
Operators and code filter records by the registered fields below. Human-readable `message` text is
context only and never determines classification, retryability, or correlation.

## Stable field table

Field names are permanent within this contract. Producers must not introduce aliases for the same
fact.

| Field | Required when | Meaning |
| --- | --- | --- |
| `timestamp` | every record | UTC RFC 3339 timestamp. |
| `level` | every record | Logger level. |
| `event` | every record | Stable dotted event name used for filtering. |
| `message` | every record | Human-readable context; never a machine classification input. |
| `source` | every record | Emitting source module and line. |
| `issue_id` | an issue is known | Linear UUID and request/work-item identity. |
| `issue_identifier` | an issue is known | Human-readable Linear key. |
| `run_id` | a persisted run is known | Symphony run identity. |
| `session_id` | a Codex session is known | Codex session identity. |
| `thread_id` | a Codex thread is known | Codex thread identity. |
| `turn_id` | a Codex turn is known | Codex turn identity. |
| `tool_call_id` | an app-server tool call is known | Exact `params.callId` value. |
| `operation` | warning/error reports an operation failure | Stable operation name. |
| `location` | warning/error reports a failure | Module, boundary, or input location. |
| `offending_value` | a rejected value exists | Safe structured representation of the rejected value. |
| `expected_shape` | warning/error reports a failure | Expected value shape or boundary contract. |
| `error_code` | warning/error reports a failure | Stable machine error code. |
| `retryable` | warning/error reports a failure | Boolean retry classification. |
| `duration_ms` | a timed operation completes | Integer elapsed milliseconds. |
| `input_tokens` | token usage is known | Input-token count. |
| `output_tokens` | token usage is known | Output-token count. |
| `total_tokens` | token usage is known | Total-token count. |
| `token_budget` | a token budget applies | Configured run budget. |
| `budget_remaining` | remaining budget is known | Tokens remaining at the observation point. |

## Producer rules

A first-party Logger call supplies `event` as literal metadata. A warning or error that reports an
operation failure also supplies `operation`, `location`, `expected_shape`, `error_code`, and boolean
`retryable`; it supplies `offending_value` and every applicable correlation field when those facts
exist. The rotating-file and console handlers both use `SymphonyElixir.LogFormatter`, so they emit
the same one-object-per-line representation.

Public API and restricted dynamic-tool failures use an envelope with stable `code`, boolean
`retryable`, human-readable `message`, `operation`, `location`, `offending_value`, and
`expected_shape`. Tool audit records copy `code` and `retryable` directly. They never infer either
field from message text.

The closed persisted run terminal classification and its write boundary remain owned by
[run-failure-classification-design.md](run-failure-classification-design.md).

## Canonical operator commands

Set `SYMPHONY_BASE_URL` to the reachable service URL and `SYMPHONY_API_TOKEN` to a valid bearer
token. The log command also requires `EVENT`, `ISSUE_ID`, `RUN_ID`, and `TOOL_CALL_ID`. The trace
command requires `ISSUE_IDENTIFIER` and `RUN_ID`. Run all commands from the repository root with
`jq` installed.

Logs:

```bash
tail -F log/symphony.log.[0-9]* | jq -c --arg event "$EVENT" --arg issue "$ISSUE_ID" --arg run "$RUN_ID" --arg call "$TOOL_CALL_ID" 'select(.event == $event and .issue_id == $issue and .run_id == $run and .tool_call_id == $call)'
```

Persisted run/event trace:

```bash
curl -fsS -H "Authorization: Bearer $SYMPHONY_API_TOKEN" "$SYMPHONY_BASE_URL/api/v1/runs?issue_identifier=$ISSUE_IDENTIFIER" | jq --arg run "$RUN_ID" '{run: (.runs[] | select(.id == $run)), events: [.events[] | select(.run_id == $run)]}'
```

Live metrics/state:

```bash
curl -fsS -H "Authorization: Bearer $SYMPHONY_API_TOKEN" "$SYMPHONY_BASE_URL/api/v1/state" | jq '{counts, codex_totals, worker_api, rate_limits}'
```

## Conformance gate

`mix observability.check` rejects unregistered Logger shapes and silent/default-success error
branches. Its single checked-in baseline is an exact, sorted inventory of reviewed legacy debt.
New, malformed, duplicate, or stale entries fail; the inventory may only shrink. The checker emits
exactly one waterline line, `observability baseline remaining: N`. When `N` reaches zero, remove the
baseline and its loading branch so all findings are hard failures.
