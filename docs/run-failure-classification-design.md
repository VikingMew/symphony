---
title: Run Failure Classification Design
genre: design
domain: [runs, persistence, observability, reliability]
status: current
language: en
updated: 2026-10-08
design_status: landed
---

# Run failure classification

Persisted runs use one closed status and failure contract. `running` and `completed` rows have
`failure_reason = NULL` and `failure_evidence = NULL`. `failed`, `blocked`, `cancelled`, and
`stopped` rows have one non-empty classification in `failure_reason` and a non-empty JSON object in
`failure_evidence`. The classification is the query and aggregation key; paths, actions, phases,
timeouts, exit codes, signals, gate results, dependency operations, Codex error information, and
opaque domain detail belong only in evidence.

A Codex startup handshake failure keeps the existing `runtime_failure` classification for the
failed run; retry exhaustion keeps `budget_exhausted`. The sole startup fact remains
`{:codex_startup_failed, details}`. Its type, `initialize` or `thread_start` stage, 30,000 ms budget,
and bounded summary belong in `failure_evidence`. The summary places those structured facts before
compressed raw startup output so output cannot push them outside the bounded detail.

## Vocabulary

| Classification | Meaning |
| --- | --- |
| `environment_unavailable` | The admission or execution environment cannot provide required filesystem or runtime access. |
| `source_preparation_timeout` | Clone, fetch, or checkout timed out. |
| `external_dependency_timeout` | A required external dependency operation timed out. |
| `budget_exhausted` | A stall, read timeout, or failure retry budget ended the run. |
| `contract_violation` | Required handoff or validated protocol evidence was missing or invalid. |
| `worker_process_termination` | A worker/Codex process, port, signal, OOM, lease, or assignment ended unexpectedly. |
| `assignment_expired` | A rejected terminal assignment expired, or an operator explicitly replaced an orphaned running assignment after its lease window. |
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

Worker terminal delivery retains the validated payload across Panel 503 responses and beyond the
former attempt limit. When delivery later succeeds, the original failure classification and its
delivery/summary evidence pass through `RunLifecycle`; no second run or substitute terminal write is
created.

When a matching terminal event fails `WorkerResult` validation, the active assignment retains only
the typed rejection and whitelisted attempted metadata. If that assignment expires before a valid
terminal event is accepted, `RunFailure` creates `assignment_expired` once from that sanitized value.
The same `RunFailure` supplies the synthetic task event, terminal run event, run row, and
orchestrator notification. An expiry with no retained terminal rejection remains
`worker_process_termination`; an invalid summary itself remains unaccepted and is never persisted as
an execution summary.

A `run.orphaned` event is observational and does not terminally classify its running run. After an
operator records the incident and moves the issue to `Todo`, explicit admission may replace a run
older than the lease window. That single transaction first finishes the old run as
`assignment_expired` with `reason = operator_manual_rerun`, `phase = admission`, and the prior run id,
then creates one new running row. Periodic reconciliation never performs this terminal write.

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

The later forward-only PostgreSQL migration replaces only `runs_failure_reason_closed` to admit
`assignment_expired`; it leaves `runs_terminal_failure_matrix` unchanged and retains historical-only
`unknown`. Operators take a `pg_dump` before applying this constraint migration. A vocabulary or
constraint correction is delivered as another forward migration rather than rolling this migration
back. The stopped SQLite importer accepts `assignment_expired` as an existing classification.
