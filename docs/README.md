---
title: Documentation Index
genre: meta
domain: [governance, docs]
status: current
language: en
updated: 2026-08-07
---

# Documentation Index

This index classifies every Markdown document directly under `docs/` by the L0-L5 layer model
(see [AGENTS.md](../AGENTS.md) and [documentation-system-design.md](documentation-system-design.md)).
Each document belongs to exactly one layer; each contract has exactly one owning document and
other documents link instead of restating.

## L0 — Governance

| Document | Purpose |
| --- | --- |
| [README.md](README.md) | This index and layer registry. |
| [decisions.md](decisions.md) | Accepted architectural and process decisions (ADR log). |
| [documentation-system-design.md](documentation-system-design.md) | Documentation governance and migration design. |
| [documentation-alignment.md](documentation-alignment.md) | Claim-level consistency matrix (canonical topic -> owning document). |

## L1 — System Architecture

| Document | Purpose |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Process topology, trust/data boundaries, cross-cutting invariants, direction. |
| [long_term_direction.zh-CN.md](long_term_direction.zh-CN.md) | System direction and technology roadmap. |

## L2 — Backend Design

| Document | Purpose |
| --- | --- |
| [design.md](design.md) | Repository layout, package conventions, module map, **Feature Design Index**. |

## L3 — Feature Designs

| Document | Purpose | Status |
| --- | --- | --- |
| [workflow-page-design.md](workflow-page-design.md) | Workflow settings page goals. | landed |
| [worker-panel-decoupling-design.md](worker-panel-decoupling-design.md) | Panel / worker execution boundary. | landed |
| [execution-runtime-design.md](execution-runtime-design.md) | Production external worker runtime, validation, artifacts, and reconciliation. | proposed |
| [workspace-source-layout-design.md](workspace-source-layout-design.md) | Workspace source layout. | landed |
| [codex-linear-interaction-design.md](codex-linear-interaction-design.md) | Codex/Linear interaction behavior. | landed |
| [codex-linear-implementation-workflow-design.md](codex-linear-implementation-workflow-design.md) | Codex/Linear implementation workflow. | landed |
| [codex-linear-task-refinement-workflow-design.md](codex-linear-task-refinement-workflow-design.md) | Codex/Linear task refinement workflow. | landed |
| [dashboard-color-system-design.md](dashboard-color-system-design.md) | Dashboard color system. | landed |
| [hot-update-design.md](hot-update-design.md) | Hot-update capability. | landed |
| [operator-profiles-standardization-design.md](operator-profiles-standardization-design.md) | Read-only operator profiles (nap / day_dreaming) single-source contract. | landed |
| [remove-default-project-dependency-design.md](remove-default-project-dependency-design.md) | Multi-project first: default project becomes optional, no auto-create. | landed |
| [default-project-bootstrap-and-remove-design.md](default-project-bootstrap-and-remove-design.md) | Default = empty-DB bootstrap anchor; manual project removal button. | landed |

## L4 — Normative Contracts

| Document | Purpose |
| --- | --- |
| [spec.md](spec.md) | Service specification overview + domain navigation. |
| [spec-domain-model.md](spec-domain-model.md) | Entities, stable identifiers, reference algorithms (§4, §16). |
| [spec-workflow-config.md](spec-workflow-config.md) | Persisted runtime contract, package format, configuration (§5-6). |
| [spec-orchestration.md](spec-orchestration.md) | Issue state machine, polling, workspace management (§7-9). |
| [spec-agent-runner.md](spec-agent-runner.md) | Coding-agent launch/streaming contract, prompts, SSH extension (§10, §12, App A). |
| [spec-linear-integration.md](spec-linear-integration.md) | Linear-compatible operations and error contract (§11). |
| [spec-observability.md](spec-observability.md) | Logging, metrics, token accounting, HTTP surface (§13). |
| [spec-reliability-security.md](spec-reliability-security.md) | Failure model, recovery, security invariants (§14-15). |
| [spec-conformance.md](spec-conformance.md) | Conformance profiles and implementation checklist (§17-18). |
| [logging.md](logging.md) | Logging contract. |
| [token_accounting.md](token_accounting.md) | Token-accounting reference. |
| [persistence_and_auth.md](persistence_and_auth.md) | Persistence and authentication reference. |
| [test_database_isolation.md](test_database_isolation.md) | Test database-isolation contract. |

## L5 — Operational Guides

| Document | Purpose |
| --- | --- |
| [user-guide.zh-CN.md](user-guide.zh-CN.md) | Operator guide (zh-CN). |
| [compose.md](compose.md) | Compose, PostgreSQL operations, backup/restore, and SQLite cutover guide. |
| [deployment.md](deployment.md) | Reverse-proxy and Kubernetes deployment guide. |

## Adding or Changing Documents

- New documents: place in exactly one layer, follow naming conventions (see
  [documentation-system-design.md](documentation-system-design.md) §4), add frontmatter, and
  register here. `mise exec -- mix docs.check` enforces structure, genre/status legality, index
  registration, and owner anchors.
- Feature designs: one concern per `*-design.md` (L3); land status in `design_status`.
- Claim changes: update the owning document (see [documentation-alignment.md](documentation-alignment.md)),
  then fix stale links elsewhere — never copy the claim into a second document.
