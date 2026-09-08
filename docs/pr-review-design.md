---
title: Post-handoff Pull Request Review Design
genre: design
domain: [codex, github, linear, review]
status: current
language: en
updated: 2026-09-08
design_status: landed
---

# Post-handoff Pull Request Review

PRReview is an independent, durable verification stage after implementation handoff. It reviews
the exact pull request head prepared by the trusted GitHub backend; it is not another issue-state
route and does not extend implementation-agent authority.

## Durable intent and recovery

The handoff boundary persists a `review_jobs` intent before moving the Linear issue to
`Ready to Merge`, then arms that intent only after the state write succeeds. The durable identity
combines project, issue, pull request URL, and immutable `head_oid`, making repeated handoff
requests idempotent for the same review target.

`PRReview.Queue` owns reconciliation, claiming, recovery, and delivery retries. It periodically
arms bounded pre-transition intents whose issues reached `Ready to Merge`, closes the crash gap
between the Linear write and queue arming, and changes jobs left `running` by a Panel restart back
to `queued`. Review execution failures without a result finish as `failed`; once a typed result is
stored, delivery failure returns the job to `queued` so completed review work is not repeated.
The exact statuses, durable identity, run/event representation, and dispatch rules are normative
in [spec-domain-model.md](spec-domain-model.md), [spec-orchestration.md](spec-orchestration.md),
and [spec-observability.md](spec-observability.md).

## Immutable, read-only review

Immediately before execution, `PRReview.Runner` revalidates that the issue is still
`Ready to Merge`, the pull request is open, and its current head equals the stored `head_oid`.
A changed state, closed pull request, or changed head supersedes the job without delivery.

The review runs in an isolated workspace with a read-only, network-disabled Codex sandbox. Its
only task capabilities are reading backend-supplied issue/PR/diff context and submitting one typed
approve-or-findings conclusion. It cannot modify the checkout, push, create a pull request, or
mutate GitHub or Linear. The normative runner and tool restrictions are owned by
[spec-agent-runner.md](spec-agent-runner.md).

## Panel deployment topology

Review queue capacity and review workspace placement belong to Panel deployment topology, not to
project workflow settings. `SYMPHONY_PANEL_MAX_CONCURRENT_REVIEWS` sets the positive review limit,
and `SYMPHONY_PANEL_WORKSPACE_ROOT` supplies the base beneath which the queue creates isolated
`.reviews/<job-id>` directories. The queue also respects the process-wide Panel agent ceiling.
All enabled projects therefore share these deployment-level resources; no project can override
them through its current workflow snapshot.

## Delivery and human authority

Delivery is idempotent and remains separate from the read-only review session. An approve result
adds a concise Linear comment and leaves the issue in `Ready to Merge`. Findings first persist a
typed `blocking_decision`, then deliver the comment and request `Ready to Merge -> Blocked`.
Existing blocker evidence is never replaced; the review job records the conflict for operator
resolution.

Neither outcome merges the pull request or moves the issue to `Done`. Human review owns change
requests and merge decisions, and Linear's merged-PR automation exclusively owns successful
completion. After a human returns an issue to `In Progress`, implementation updates the same
branch and pull request; a later handoff creates a review target only for the newly resolved
immutable head. The normative tracker transitions and delivery ordering are owned by
[spec-linear-integration.md](spec-linear-integration.md) and
[spec-workflow-config.md](spec-workflow-config.md).
