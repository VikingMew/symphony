---
layer: L3
status: implemented
domain: [worker, execution, validation]
language: en
---

# External execution runtime

The optional execution worker is a separately deployed, non-root execution plane. The Panel owns
Linear access, workflow/profile selection, prompt construction, dispatch, and the one active
in-memory assignment. The worker owns checkout, hooks, one Codex app-server turn, required gates,
PR handoff, bounded evidence, and cleanup.

A claim is created from a live Linear candidate read and a second state/dependency/routing check.
The Panel moves the issue to `In Progress` before returning the current-workflow payload. The
assignment ID is carried in the existing `task_id` and `lease_id` JSON fields; it is not a database
task. The payload contains the issue, exact branch, source ref, rendered profile prompt, hooks,
Codex settings, limits, ordered required gates, and allowed handoff updates. The worker has neither
a Linear client nor a Linear credential.

One supervised process group owns checkout, hooks, Codex, validation, and handoff for an assignment.
It renews only that assignment and emits accepted/progress/completed/failed/cancelled events with
project, issue, run, worker/session, and assignment correlation. The Panel rejects expired or
mismatched events. Restricted Linear tool audits use the same worker task-event endpoint: the
worker sends a non-terminal `linear.tool_call` event with assignment correlation, and only the
Panel persists it. Audit delivery failures are logged as degraded execution and do not change the
tool response or assignment lifecycle. Centralized execution records the same audit locally in the
Panel.

A terminal failure, worker loss, or expiry ends the run and assignment. There is no task requeue. A
later run can start only after a new live Linear claim proves the issue eligible. Manual Blocked,
Done, or review-state changes therefore take effect at the next check.

Panel restart deliberately loses the assignment and payload. Reconciliation uses Linear `In
Progress` state plus latest persisted run/event time: no duplicate is dispatched before timeout,
then an expired zombie is moved to `Ready` and its old run is failed. Late events are rejected.
PostgreSQL stores worker/session identity and run/event history, never queued work or active leases.

Centralized mode remains the default. Worker mode is opt-in. Multi-worker scheduling, distributed
claim, and a separate verifier are outside this contract. Implementation validation may statically
inspect deployment configuration but does not run container engines or image-level checks.
