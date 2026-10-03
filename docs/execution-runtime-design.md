---
title: External Execution Runtime Design
genre: design
domain: [worker, execution, validation]
status: current
language: en
updated: 2026-10-03
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

The checked-in `compose.host-override.yaml` makes the execution worker credential boundary
explicit. The existing `execution_worker_codex` named volume remains mounted at
`/home/symphony/.codex` for Codex configuration, logs, and session data. A deeper bind mount maps
the existing host `auth.json` named by the required
`SYMPHONY_EXECUTION_WORKER_CODEX_AUTH_FILE` parameter onto
`/home/symphony/.codex/auth.json`; `bind.create_host_path: false` makes a missing source file a
deployment error. Compose does not load this non-default override automatically, so every worker
deployment command must name it.

This bind shares the host's account-level Codex login rather than a worker-scoped token. The worker
therefore has every permission granted to that login, and compromise of the worker exposes the same
credential boundary as compromise of the host login. Host and worker refreshes can race: one side's
single call may fail after the other rotates the refresh state, then recover on its next call after
reading the updated shared file. The named volume's older `auth.json` is neither migrated nor
deleted; the deeper bind is authoritative while the override is loaded.

A claim enters through the Orchestrator mailbox and is admitted against the current in-memory
listening mode before any Linear candidate read. `not_listening` returns an empty claim immediately;
`listening_refine_only` filters each sorted candidate through the same refinement-state policy used
by centralized dispatch, so an earlier implementation candidate cannot hide a later refinement
candidate; `listening_all` admits both profiles. An admitted claim is then created from a live Linear
candidate read, absence of an uncleared persisted `blocking_decision`, and a second
state/dependency/routing/listening/blocking-decision check. Candidate fetch, revalidation, and the
started-state write run in one supervised task under a 5000 ms budget, while the assignment manager
retains the single in-flight claim reservation and continues serving lease and event calls. A
timeout terminates that task and returns the existing `{:linear_api_request, :timeout}` tracker
failure with 30/60-second poll backoff; the public manager claim uses a bounded 6000 ms call timeout
instead of `:infinity`. The Panel
derives the worker started state from the single `AgentRunner.Policy` profile-to-started-state
contract: refinement claims validate and apply `Todo -> Refining`, while implementation claims
validate and apply `Ready -> In Progress`. The assignment is returned only after that Linear state
update succeeds. The assignment issue, payload issue, and rendered prompt current state use the
started state, so refinement worker completions operate from `Refining -> Needs Refinement Review`
and implementation handoff still operates from `In Progress -> Ready to Merge`. The assignment ID
is carried in the existing `task_id` and `lease_id` JSON fields; it is not a database task. The
payload contains the issue description, exact branch, source ref, rendered profile prompt, hooks, Codex
settings, limits, ordered required gates, and allowed handoff updates. The worker has neither a
Linear client nor a Linear credential.

For the stall timeout, the resolved combined workflow field is `codex.stall_timeout_ms`. The Panel
copies that value into assignment `limits.stall_timeout_ms`, and
`SymphonyElixir.Worker.ExecutionPayload.from_task_payload/1` maps it to worker-v1
`codex.stall_timeout_ms` for `SymphonyElixir.Worker.Payload.parse/1`. This boundary defines no second
timeout source. [Orchestration §8.5](spec-orchestration.md#85-active-run-reconciliation) owns the stall decision
contract.

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
Panel. For one Codex session, the worker also retains only the successful `create_pull_request` and
state-name-normalized `linear_task_update(target_state: "Ready to Merge")` audit fields needed to
classify a missing final handoff. The successful PR event must provide its URL; branch and commit are
included when present. When both calls succeeded but no `handoff` was submitted, the executor
reports `blocked` / `handoff_failed` with that bounded PR and Linear target-state evidence. Without
that pair or the host-push predicate below, a missing `handoff` remains
`{:handoff_failed, :missing_handoff}` and its bounded detail names the missing event or PR URL.

For implementation assignments, an accepted `handoff` dynamic-tool call only captures the final
comment/result/references in the Codex turn and reports `linear_updated: false`. Except for the two
structured blocker predicates, the executor requires that payload before invoking
`Validation.run/3`; once every required gate passes, it adds the fixed `Ready to Merge` target and
performs the restricted Linear writeback. No Codex-side `linear_task_update` completion request is
part of this worker path.

The same assignment lifecycle feeds the Panel's live orchestrator snapshot. A successful claim that
creates the worker run, applies the profile-derived started state, and returns the assignment enters
`running`. Progress events can carry `codex_session_started` or a Codex app-server message under the
task progress payload; the Panel uses those messages to update session identity, last event/message,
rate limits, and absolute token totals with the same delta accounting as centralized execution.
Terminal events, cancellation, expiry, and stale-run reconciliation leave `running`; successful or
cancelled endings clear the current entry, failed endings either enter orchestrator retry state or,
when exhausted, persistent blocking, and blocked endings create the same persistent blocker path as
centralized blocked outcomes. An implementation with no handoff is classified as host-push only
when the payload issue description's first line that is non-empty after trimming, itself trimmed of
surrounding whitespace, is exactly `交付路径:宿主 push` and the workspace root contains
`<issue-identifier>.patch`. After required gates run, the worker emits
`blocked` / `handoff_failed` with only that root-relative path and `需宿主 push`; self-reported
blocked payloads, marker-only, patch-only, and permission-detail-only signals do not qualify.

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
`not_run`; its bounded detail also names the missing completed-delivery event or PR URL. The two
structured missing-final-handoff blockers run validation first, remain `blocked` when a gate fails,
and preserve the actual result in the terminal summary. Failure detail is serialized from structured
executor terms and never uses Elixir `inspect/1` syntax.

`agent.max_retry_backoff_ms` caps only orchestrator failure-retry scheduling. A worker claim request
contains no issue identifier for a prospective assignment and the worker keeps no per-issue retry or
cooldown state. Worker re-claim cadence follows the Panel's `poll_after_seconds` response and the
next claim is governed by Panel admission, including any persisted `blocking_decision`.

Listening off stops all future dispatch, including worker HTTP claims, before candidate reads, run
creation, issue transition, or `task.accepted` persistence. Start-listening, stop-listening, and the
full worker claim admission/creation transaction share the Orchestrator mailbox boundary. Therefore
a successful stop response waits for any earlier claim to finish, and every claim admitted afterward
sees `not_listening`. An ordinary stop does not alter an existing assignment or running Codex turn.
Force-stop and cancel-current are explicit cancellation controls. Force-stop turns listening
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
current matching in-memory assignment. Claim and reconciliation tracker I/O runs outside the
assignment manager process, so this renewal section contains only in-memory lease/cancellation
transitions. If that bounded renewal section cannot complete in time, the
Panel returns HTTP 503 with `worker_heartbeat_unavailable`, `retry_after_seconds`, and
`Retry-After`; worker/session history-write delay or failure cannot produce that response and does
not create a task, assignment, run failure, metric increment, or repair action.

A terminal failure, worker loss, or expiry ends the run and assignment. There is no task requeue. A
later run can start only after a new live Linear claim proves the issue eligible. Every persistent
blocker producer uses `BlockingDecision.new/6` with the live Linear state and owning non-empty run
id: failure and no-progress use the current running entry, merge conflict uses the second
`Ready to Merge` read plus completed handoff run, and review findings use the review run plus their
delivery-time `Ready to Merge` read. Persisted issue state is never a producer scope source.

Candidate selection and tracker revalidation share one validity rule. A completed transition
expects live `Blocked`; every other decision expects `origin_state`. That state and the decision
`run_id` must match the latest persisted issue run. Missing scope is typed `missing_scope`; a state
mismatch or newer run also makes the decision stale. The same claim compares the observed JSON and
atomically clears `blocking_decision` / `no_progress_streak` to `NULL` / `0`, releases only the old
run's blocked, retry, failure, and stale-claimed projection, records the scoped clear event, and
continues later gates. A replacement race is re-read without clearing its streak or projections,
and a same-claim newer running projection remains intact. A manually newer run is explicit retry
intent. Persisting a terminal blocker cancels pending automatic retry so a valid blocker cannot
immediately invalidate itself. Valid blocker claims retain `reason: blocking_decision`; their skip
logs include issue, reason, origin state, run id, and decision time. The one-time migration enriches
only non-null decision JSON that lacks `origin_state`, using `issues.state`; an already scoped
decision is unchanged, including on a repeated migrator invocation. Neither existing database
column is removed. The database-free worker suite covers equivalent post-cutover fixtures, while
the opt-in PostgreSQL smoke is the host-run proof for the migration and column assertions.

Listening rejection evidence is `{reason: not_listening, capacity: 0, listening_mode:
not_listening}`. A refine-only batch containing no refinement candidate uses `reason:
listening_mode` with the current mode. Both paths log `event=worker_claim_skip` with worker/session,
reason, mode, and capacity. These response and log fields use the same Orchestrator mode exposed by
the control and state APIs; no listening value is persisted in the assignment manager or workflow.

Panel restart deliberately loses the assignment and payload. Each reconciliation round deduplicates
enabled workflows by `tracker.project_slug`, then a single supervised task performs one Linear `In
Progress` fetch per distinct slug plus the corresponding zombie transition. The whole task has a
5000 ms budget; timeout terminates the round, no later round overlaps it, and the manager accepts
only the current round-reference result cast. Tracker errors and timeouts use distinct
`worker_reconcile_tracker_error` and `worker_reconcile_tracker_timeout` logs rather than the run's
`assignment_expired` terminal event. Reconciliation combines those Linear results with latest
persisted run/event time: no duplicate is dispatched before timeout, then an expired zombie is moved
to `Ready` and its old run is failed. Late events are rejected.
PostgreSQL stores worker/session identity and run/event history, never queued work or active leases.

Centralized mode remains the default. Worker mode is opt-in. Multi-worker scheduling, distributed
claim, and a separate verifier are outside this contract. Implementation validation may statically
inspect deployment configuration but does not run container engines or image-level checks.
