---
title: External Execution Runtime Design
genre: design
domain: [worker, execution, validation]
status: current
language: en
updated: 2026-09-12
design_status: landed
---

# External execution runtime

The optional execution worker is a separately deployed, non-root execution plane. The Panel owns
Linear access, workflow/profile selection, prompt construction, dispatch, and the one active
in-memory assignment. The worker owns checkout, hooks, one Codex app-server turn, required gates,
PR handoff, bounded evidence, and cleanup.

In the current containerized worker deployment, the worker container is the execution isolation
boundary. Worker-internal Codex turns do not depend on a nested bubblewrap user namespace; the
checked-in import package therefore carries `thread_sandbox: "danger-full-access"` and
`turn_sandbox_policy.type: "dangerFullAccess"` for that deployment shape. The container boundary is
kept by Compose and image policy, not by relaxing host seccomp or adding container-engine access
inside the worker.

A claim is created from a live Linear candidate read and a second state/dependency/routing check.
The Panel derives the worker started state from the single `AgentRunner.Policy`
profile-to-started-state contract: refinement claims validate and apply `Todo -> Refining`, while
implementation claims validate and apply `Ready -> In Progress`. The assignment is returned only
after that Linear state update succeeds. The assignment issue, payload issue, and rendered prompt
current state use the started state, so refinement worker completions operate from `Refining ->
Needs Refinement Review` and implementation handoff still operates from `In Progress -> Ready to
Merge`. The assignment ID is carried in the existing `task_id` and `lease_id` JSON fields; it is not
a database task. The payload contains the issue, exact branch, source ref, rendered profile prompt,
hooks, Codex settings, limits, ordered required gates, and allowed handoff updates. The worker has
neither a Linear client nor a Linear credential.

History-based duplicate-run gating treats only `Refining` and `In Progress` as worker started
states. A candidate in either state can be claimed only when the latest worker run is terminal
(`succeeded`, `failed`, or `cancelled`); a non-terminal latest worker run prevents duplicate
assignment. Repository defaults still leave `tracker.active_states` at `Todo`, `Ready`, and
`In Progress`, so `Refining` is not a default dispatch state.

One supervised process group owns checkout, hooks, Codex, validation, and handoff for an assignment.
It renews only that assignment and emits accepted/progress/completed/failed/cancelled events with
project, issue, run, worker/session, and assignment correlation. The Panel rejects expired or
mismatched events. Restricted Linear tool audits use the same worker task-event endpoint: the
worker sends a non-terminal `linear.tool_call` event with assignment correlation, and only the
Panel persists it. Audit delivery failures are logged as degraded execution and do not change the
tool response or assignment lifecycle. Centralized execution records the same audit locally in the
Panel.

The same assignment lifecycle feeds the Panel's live orchestrator snapshot. A successful claim that
creates the worker run, applies the profile-derived started state, and returns the assignment enters
`running`. Progress events can carry `codex_session_started` or a Codex app-server message under the
task progress payload; the Panel uses those messages to update session identity, last event/message,
rate limits, and absolute token totals with the same delta accounting as centralized execution.
Terminal events, cancellation, expiry, and stale-run reconciliation leave `running`; successful or
cancelled endings clear the current entry, failed endings either enter orchestrator retry state or,
when exhausted, persistent blocking, and blocked endings create the same persistent blocker path as
centralized blocked outcomes.

If the Codex command-execution capability is unavailable inside the worker, including the known
bwrap/user-namespace failure mode, the worker reports a terminal failed outcome with a distinct
reason instead of leaving the assignment `In Progress` until a stall or turn timeout.

Heartbeat is a success/renewal signal, not queued work and not a synchronous worker/session
database-write gate. After controller identity/protocol parsing, the Panel records worker/session
freshness through a coalesced asynchronous history observer whose result is ignored by the worker-v1
protocol. Heartbeats that report no active lease return success with an empty renewal list without
entering the assignment manager queue. Heartbeats that report an active lease can renew only the
current matching in-memory assignment. If that bounded renewal section cannot complete in time, the
Panel returns HTTP 503 with `worker_heartbeat_unavailable`, `retry_after_seconds`, and
`Retry-After`; worker/session history-write delay or failure cannot produce that response and does
not create a task, assignment, run failure, metric increment, or repair action.

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
