---
title: Issue Persistence Boundary Design
genre: design
domain: [issues, persistence, linear, observability]
status: current
language: en
owner: SymphonyElixir.Persistence.IssueRecord
updated: 2026-10-07
design_status: landed
---

# Issue persistence boundary

The `issues` table anchors runs, review jobs, and worker-owned issue metadata. It stores the tracker
identity, selected display scalars, the last persisted poll snapshot, `blocking_decision`, and
`no_progress_streak`. Linear issue state has one persisted representation:
`snapshot["state"]`. There is no independent `issues.state` column.

The normalized in-memory `SymphonyElixir.Linear.Issue.state` is authoritative for dispatch, claim,
reconciliation, and transition decisions. Poll persistence replaces the snapshot when a candidate
is observed. An issue that leaves the poll candidate set can therefore retain its last observed
snapshot state. That value is historical evidence and does not claim to be the current Linear
state.

Linear transition delivery records delivery evidence in worker-owned fields. Blocking delivery
updates the canonical `blocking_decision`; post-handoff review delivery updates its review job.
Neither path rewrites the poll snapshot or maintains another tracker-state mirror.

## Atomic running-run admission

Worker admission upserts the project issue, locks that issue row, checks its running issue run, and
creates a new run in one transaction. A partial unique index on `runs.issue_id` where the issue run
is `running` enforces the invariant across independent callers. The forward migration resolves any
pre-existing duplicates deterministically by retaining the oldest running row and failing later
rows with structured migration evidence before adding the index.

An existing running row normally returns `{:active_run, run_id}` and produces no assignment. A live
`Todo` candidate is explicit operator rerun intent only when the existing row predates the assignment
lease cutoff. The transaction then closes that orphan through `RunLifecycle` with
`assignment_expired` / `operator_manual_rerun` evidence before inserting exactly one replacement.
Periodic orphan detection only records `run.orphaned`; it never changes Linear state or the run.

## History projection

Persisted observability keeps the `persisted_issue.state` response key for its existing response
shape. `SymphonyElixir.ObservabilityHistory` projects that value from the same row's
`snapshot["state"]`. The inactive issue response uses that projection for top-level `status`, so the
API and Issue Detail expose the same last-poll evidence.

## Schema and cutover

The removal migration drops `issues.state`. Its rollback restores only a nullable text column; it
cannot restore discarded mirror values. Reapplying the migration drops the empty column again.

The stopped SQLite source may contain its legacy `issues.state` column. `SymphonyElixir.SQLiteImporter`
selects only current target columns and therefore ignores that source value while retaining the
source snapshot and all issue/run foreign-key identities.
