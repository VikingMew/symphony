---
title: Observability and Tool Error Design
genre: design
domain: [observability, logging, errors]
status: current
language: en
updated: 2026-10-10
design_status: landed
---

# Observability and tool errors

This design owns the first-party JSON Lines logging contract, the stable log field registry,
public and restricted dynamic-tool error-envelope requirements, run/tool correlation identifiers,
the three canonical operator commands, and the O-specific deletion-only source gate.

It does not own persisted run terminal classification. The closed terminal vocabulary, evidence
contract, runtime mapping, and terminal write boundary remain solely owned by
[Run Failure Classification Design](run-failure-classification-design.md).

## Structured log boundary

The default console handler and rotating disk handler use `SymphonyElixir.LogFormatter`. Every
physical record is one JSON object with the required fields in [Logging Best
Practices](logging.md). A Logger call may retain a human `message`, but filtering and joins use the
registered fields. Legacy calls without an explicit event receive `application.log`; the source
gate keeps those calls visible as debt until each call supplies its own registered metadata.

The rotating handler is startup-critical. Configuration failures return a typed error after
emitting the registered `log.handler.configure_failed` event. The runtime does not install a text
writer, dual schema, or compatibility parser.

## Error envelopes

Public HTTP failures and restricted dynamic-tool failures expose a stable `code`, boolean
`retryable`, and human `message`. Restricted tools additionally expose structured operation,
location, offending value, and expected-shape fields. Callers and audits use `code` and
`retryable` directly; message wording does not select a class or retry decision.

This envelope vocabulary describes request/tool failures only. It is not a second vocabulary for
persisted run terminal outcomes.

## Correlation

`issue_id` is the request/work-item identity. Symphony does not duplicate it as `request_id`.
Codex app-server `params.callId` becomes `tool_call_id` and is carried through
`ToolRequestHandler`, `DynamicTool`, `LinearToolAudit`, worker task-event forwarding, persisted
`linear.tool_call` payloads, and history presentation. When applicable, the same record also carries
`run_id`, `session_id`, `thread_id`, and `turn_id`.

The restricted-tool envelope and audit payload are further owned by
[Codex/Linear Interaction Design](codex-linear-interaction-design.md). Worker transport is further
owned by [External Execution Runtime Design](execution-runtime-design.md).

## Operator entry points

[Logging Best Practices](logging.md#canonical-operator-commands) owns exactly one runnable command
for JSONL logs, persisted run/event traces, and live metrics/state. These commands use the existing
log files and authenticated HTTP API; this design adds no tracing service, metrics store, APM, or
telemetry backend.

## Deletion-only ratchet

`mix observability.check` scans first-party `lib/**/*.ex` sources for Logger calls without the
registered metadata shape and silent rescue/catch/default-success error branches. Every finding has
an exact path, content-derived stable identifier, and reason. The single
`config/observability_baseline.yml` inventory is sorted and may only shrink:

- a finding absent from the inventory fails;
- malformed, duplicate, unsorted, or stale inventory entries fail;
- no wildcard, due date, alternate allowlist, or runtime flag exists;
- output contains one deterministic `observability baseline remaining: N` line.

Both ordinary `mix observability.check` and
`mix observability.check --write-baseline` load the inventory at the real `origin/main` merge base.
The deletion-only key is a multiset of `(content-derived identifier without its duplicate-number
suffix, reason)`. Path-only movement preserves that key; another occurrence increases its count and
fails. The writer builds the exact sorted `path + identifier + reason` candidate in memory, validates
the merge-base ceiling, and only then replaces the file. It is only for path refreshes and stock
deletion, never new debt. Git, base parsing, or ratchet failure leaves the target byte-identical; a
second successful run is a byte-level no-op.

When the waterline reaches zero, the baseline file and the baseline-loading branch are deleted, so
all findings become hard failures. A nonzero waterline is incomplete conformance and must remain
visible in the O-clause audit.

## Acceptance evidence

- Console and rotating-file formatter tests decode every selected record as JSON and filter by
  event and correlation fields.
- Dynamic-tool and audit tests assert exact codes/retryability and prove message changes do not
  change classification.
- Centralized and worker tests join one tool call by `issue_id`, `run_id`, `session_id`, and
  `tool_call_id`.
- Checker fixtures cover passing, new, malformed, duplicate, stale, alternate-exemption,
  path-move, multiplicity, deletion, unchanged-on-failure, and deterministic-output cases.
- Existing duration and token/budget aggregation tests remain the O-08 evidence.
