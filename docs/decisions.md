---
title: Decision Log
genre: meta
domain: [governance, decisions]
status: current
language: en
updated: 2026-08-27
---

# Decision Log

### Elixir/Phoenix control plane for the diverged fork

Status: accepted

The fork retained Symphony's orchestration model but diverged into an Elixir/Phoenix control
plane. BEAM supervision fits the long-running orchestration workload, while Phoenix supplies the
operator UI and service boundary without a separate frontend stack.

### SQLite-backed runtime settings

Status: superseded by PostgreSQL runtime persistence

SQLite workflow versions were the runtime authority before plan 259. SQLite is now only a frozen,
one-way cutover source and cannot be selected as a runtime backend.

### PostgreSQL runtime persistence

Status: accepted

PostgreSQL is the sole runtime database and `DATABASE_URL` is the connection contract. Active
workflow versions remain the durable authority, while normal `WorkflowStore` reads use the atomic
in-memory snapshot established by plan 257. Plan 259 owns the one supported stopped-SQLite-backup
cutover into an already-migrated empty PostgreSQL database.

### Per-project workflow versions and multi-project runtime

Status: accepted

Each enabled project owns its active workflow version and project-scoped runtime settings. Plans
215-219 established a single orchestrator that iterates those project contexts while preserving
default-project compatibility for existing callers.

### Checked exec-plan lifecycle

Status: accepted

Implementation work is recorded as indexed active or completed exec plans with verification and
handoff evidence. `mix exec_plans.check` enforces index membership so lifecycle state is explicit
and historical plans remain discoverable.

### Quality-gate debt cleanup

Status: accepted

Plans 221-224 treated static-analysis debt as bounded cleanup instead of weakening the gates:
Credo failing-priority findings went to zero, and Dialyzer went from 117 warnings to zero while
preserving the regression suite.

### Promote `elixir/` to the repository root

Status: accepted

The fork is now an Elixir/Phoenix product rather than a repository containing an optional Elixir
implementation. Plan 226 owns the history-preserving promotion of the Elixir project and docs to
the repository root; this decision log does not perform that move.

### Adopt the L0-L5 documentation model

Status: accepted

Documentation is classified into one of six authority layers, with one owning document for each
contract and links elsewhere. Plan 225 establishes the index, metadata seed, and checker before
plan 227 performs naming convergence and the full frontmatter sweep.
