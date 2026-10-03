---
title: Run Failure Classification Design
genre: design
domain: [runs, persistence, observability, reliability]
status: current
language: en
updated: 2026-09-27
design_status: landed
---

# Run failure classification

Persisted runs use one closed status and failure contract. `running` and `completed` rows have
`failure_reason = NULL` and `failure_evidence = NULL`. `failed`, `blocked`, `cancelled`, and
`stopped` rows have one non-empty classification in `failure_reason` and a non-empty JSON object in
`failure_evidence`. The classification is the query and aggregation key; paths, actions, phases,
timeouts, exit codes, signals, gate results, dependency operations, Codex error information, and
opaque domain detail belong only in evidence.

## Vocabulary

| Classification | Meaning |
| --- | --- |
| `environment_unavailable` | The admission or execution environment cannot provide required filesystem or runtime access. |
| `source_preparation_timeout` | Clone, fetch, or checkout timed out. |
| `external_dependency_timeout` | A required external dependency operation timed out. |
| `budget_exhausted` | A stall, read timeout, or failure retry budget ended the run. |
| `contract_violation` | Required handoff or validated protocol evidence was missing or invalid. |
| `worker_process_termination` | A worker/Codex process, port, signal, OOM, lease, or assignment ended unexpectedly. |
| `validation_failed` | A required validation gate failed, timed out, or returned non-zero. |
| `runtime_failure` | A typed agent/operator/runtime domain failure not covered by a narrower class. |
| `codex_upstream_capacity` | A validated Codex turn failure classified upstream as capacity exhaustion. |
| `codex_turn_failed` | Another validated Codex turn failure. |
| `cancelled` | The run received a cancellation terminal outcome. |
| `operator_stopped` | An operator or reconciliation stop ended the run. |
| `unknown` | Historical-only marker written by migration or one-time SQLite cutover normalization. |

`SymphonyElixir.RunFailure.classifications/0` exposes the application-write vocabulary and omits
`unknown`. It has explicit clauses for typed local causes and validated worker summaries. It has no
catch-all that converts an arbitrary term to `unknown` or `runtime_failure`; callers wrap opaque
claim, transition, agent, operator, or blocked detail in the corresponding typed tag first.

## Write boundary

`SymphonyElixir.RunFailure` is the only runtime classification boundary.
`SymphonyElixir.RunLifecycle` is the only application runtime boundary that writes a terminal run.
It accepts `:completed` or a `RunFailure` value and writes status, timestamp, reason, evidence, and
same-transition attributes such as `execution_summary` in one update. `Persistence.finish_run/4`
delegates to that boundary. Ordinary `Persistence.update_run/2` remains available for non-terminal
updates.

Worker terminal classification is derived once from the validated summary. The same value supplies
the run row, terminal event, retry metadata, `BlockingDecision.reason`, and the environment failure
circuit key. The wire summary remains execution evidence and is not a second classification source.
Explicit blocked outcomes remain accepted without interpreting their opaque reason or detail.

Run terminal events and bounded run-history API projections expose the persisted reason and
evidence together. The environment failure circuit compares classification strings exactly; its
threshold, window, success reset, explicit reset, and admission behavior are unchanged.

## Historical conversion

The forward-only PostgreSQL migration adds the JSONB column, converts `success` and `succeeded` to
`completed`, clears failure fields for running/success rows, and classifies non-success history
before installing constraints. Recognizable filesystem, source timeout, and Linear transport
timeout text receives the corresponding classification. Existing vocabulary values are retained.
All other non-success rows receive `unknown`; the old non-empty text is retained as
`legacy_failure_reason`, while a NULL reason receives an explicit migration marker.

The stopped SQLite importer performs the same status and reason normalization before its raw bulk
insert. Any status outside the closed lifecycle vocabulary fails migration/import instead of being
guessed. These are one-time conversion boundaries and do not introduce runtime compatibility
branches or dual writes.
