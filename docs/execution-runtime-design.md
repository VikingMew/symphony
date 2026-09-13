---
title: External Execution Runtime Design
genre: design
domain: [worker, execution, validation]
status: current
language: en
updated: 2026-09-13
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

A claim is created from a live Linear candidate read, absence of an uncleared persisted
`blocking_decision`, and a second state/dependency/routing/blocking-decision check. The Panel
derives the worker started state from the single `AgentRunner.Policy` profile-to-started-state
contract: refinement claims validate and apply `Todo -> Refining`, while implementation claims
validate and apply `Ready -> In Progress`. The assignment is returned only after that Linear state
update succeeds. The assignment issue, payload issue, and rendered prompt current state use the
started state, so refinement worker completions operate from `Refining -> Needs Refinement Review`
and implementation handoff still operates from `In Progress -> Ready to Merge`. The assignment ID
is carried in the existing `task_id` and `lease_id` JSON fields; it is not a database task. The
payload contains the issue, exact branch, source ref, rendered profile prompt, hooks, Codex
settings, limits, ordered required gates, and allowed handoff updates. The worker has neither a
Linear client nor a Linear credential.

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
Panel persists it. The forwarded audit surface includes every `linear_task_read`,
`linear_task_update`, `linear_issue_create`, `create_pull_request`, and `handoff` call, with one
event for each success or failure. PR success evidence is bounded to URL and repository/base/head
metadata; accepted handoff results are bounded, and credentials, tokens, and completion proofs are
redacted before persistence. Failure payloads retain stable class/message and available reason
fields. Audit delivery failures are logged as degraded execution and do not change the tool
response or assignment lifecycle. Centralized execution records the same audit locally in the
Panel. A missing `handoff` event remains distinct from a failed `handoff` event, so
`require_handoff/2` continues to report `{:handoff_failed, :missing_handoff}` only when no handoff
was submitted.

For implementation assignments, an accepted `handoff` dynamic-tool call only captures the final
comment/result/references in the Codex turn and reports `linear_updated: false`. The executor requires
that payload before invoking `Validation.run/3`; once every required gate passes, it adds the fixed
`Ready to Merge` target and performs the restricted Linear writeback. No Codex-side
`linear_task_update` completion request is part of this worker path.

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

Terminal summaries report validation evidence from the executor result rather than inferring it
from the terminal event type. When validation ran, `validation_status` reflects its overall result
and `gates` contains the ordered gate results that actually ran. When execution ends before
validation, `validation_status` is `pending` and every required gate from the assignment is emitted
as `not_run`; the list is empty only when the assignment declared no required gates. In particular,
a missing implementation handoff fails before validation with reason `handoff_failed`, preserves
`missing_handoff` in deterministic JSON detail, and marks the assignment's required gates
`not_run`. Failure detail is serialized from structured executor terms and never uses Elixir
`inspect/1` syntax.

Listening off only stops future dispatch. It does not alter an existing assignment or running Codex
turn. Force-stop and cancel-current are explicit cancellation controls. Force-stop turns listening
off, keeps the existing centralized rollback/force-stop behavior, and cancels the current worker
assignment through the same assignment-scoped path used by cancel-current. Cancel-current targets
only the current in-memory worker assignment and does not change listening mode; when `project_id`
is supplied, it matches only that project and reports no active assignment on mismatch.

Worker cancellation is a synchronous control result backed by an in-band worker handshake. The
Panel records a pending cancellation on the current assignment and returns a `cancel_task` command
only to the owning worker/session heartbeat that still reports the matching active lease. That lease
is not renewed after the cancel command is delivered. The worker logs the command, emits
`task.progress` with phase `cancelling`, stops the executor, closes the active Codex app-server
session, terminates the recorded app-server process, and then reports terminal `task.cancelled`.
The Panel accepts the result as `cancelled` only after that terminal event is persisted, the run is
transitioned to `cancelled`, and the orchestrator has been notified of `:cancelled`.

The shared cancellation result has three meanings. `cancelled` means one matching assignment was
terminally cancelled and the worker-side Codex execution for that assignment has stopped.
`no_active_assignment` means no current in-memory assignment matched the request, so no worker stop
was requested and the response says nothing about stale worker-local processes. `failed` means the
required server-side event/run transition, worker cancel delivery, or worker-side termination did
not complete or could not be verified within the cancellation window. Force-stop returns this typed
shape in `cancelled_tasks` while preserving its existing top-level keys.

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
later run can start only after a new live Linear claim proves the issue eligible and no uncleared
`blocking_decision` exists. Manual Blocked, Done, review-state changes, and persisted blocker clears
therefore take effect at the next check. When a persisted blocker exists, empty claim evidence uses
`reason: blocking_decision` and the Panel logs `event=worker_claim_skip` with issue and worker/session
context; after `BlockingDecision.clear/1`, the same active issue can be claimed again if dependency,
routing, and run-history gates pass.

Panel restart deliberately loses the assignment and payload. Reconciliation uses Linear `In
Progress` state plus latest persisted run/event time: no duplicate is dispatched before timeout,
then an expired zombie is moved to `Ready` and its old run is failed. Late events are rejected.
PostgreSQL stores worker/session identity and run/event history, never queued work or active leases.

Centralized mode remains the default. Worker mode is opt-in. Multi-worker scheduling, distributed
claim, and a separate verifier are outside this contract. Implementation validation may statically
inspect deployment configuration but does not run container engines or image-level checks.
