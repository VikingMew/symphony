---
title: Issue Persistence Boundary Design
genre: design
domain: [issues, persistence, linear, observability]
status: current
language: en
owner: SymphonyElixir.Persistence.IssueRecord
updated: 2026-10-03
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
