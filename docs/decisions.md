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

SQLite workflow versions were the former runtime authority. SQLite is now only a frozen,
one-way cutover source and cannot be selected as a runtime backend.

### PostgreSQL runtime persistence

Status: accepted

PostgreSQL is the sole runtime database and `DATABASE_URL` is the connection contract. Active
workflow versions remain the durable authority, while normal `WorkflowStore` reads use an atomic
in-memory snapshot. The only supported cutover imports a stopped SQLite backup into an
already-migrated empty PostgreSQL database.

### Per-project workflow versions and multi-project runtime

Status: accepted

Each enabled project owns its active workflow version and project-scoped runtime settings. Plans
215-219 established a single orchestrator that iterates those project contexts while preserving
default-project compatibility for existing callers.

### Linear task definition and PR-first delivery

Status: accepted

Linear owns task definition, refinement state, and ordering. GitHub pull requests and commits own
implementation review and delivery evidence; repository documentation owns only current contracts,
designs, decisions, and operational guidance.

### Quality-gate debt cleanup

Status: accepted

Static-analysis debt was treated as bounded cleanup instead of weakening the gates:
Credo failing-priority findings went to zero, and Dialyzer went from 117 warnings to zero while
preserving the regression suite.

### Promote `elixir/` to the repository root

Status: accepted

The fork is now an Elixir/Phoenix product rather than a repository containing an optional Elixir
implementation. The Elixir project and docs live at the repository root.

### Adopt the L0-L5 documentation model

Status: accepted

Documentation is classified into one of six authority layers, with one owning document for each
contract and links elsewhere. The index, metadata, checker, naming, and frontmatter conventions
enforce that model.
