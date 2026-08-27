---
title: Documentation Alignment Matrix
genre: meta
domain: [governance, alignment]
status: current
language: en
updated: 2026-08-27
---

# Documentation Alignment Matrix

This matrix records claim-level ownership: each long-lived topic has exactly one owning
document (single source of truth); other documents link instead of restating. It is the review
checklist for keeping product direction, architecture, operator docs, and active plans
consistent. `mix docs.check` enforces document structure; this matrix tracks claim ownership.

## Canonical Topics

| Topic | Canonical current doc | Owning plans | Current truth |
| --- | --- | --- | --- |
| Runtime configuration source | `README.md`, `docs/user-guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md` | 080, 097, 119, 120, 152, 216-219, active 257 | SQLite active workflow versions remain durable authority. Cold start and successful mutations atomically publish one in-memory per-project/default/source snapshot; normal runtime reads never query SQLite. Background refresh is single-flight, generation-guarded, and last-known-good. Split YAML files remain import/export artifacts, not runtime fallback. |
| Settings ownership | `docs/workflow-page-design.md`, `docs/long_term_direction.zh-CN.md`, `README.md` | 077, 081-089, 132, 140, 219 | `/settings/projects` owns project slug/repository/source strategy and per-project hook overrides. `/settings/workflow`, `/settings/agents`, `/settings/runtime` are per-project: the Settings header switcher selects which project's versions are edited, and the workflow/agents/runtime/import tabs read and save that project's records. Project selection is Settings chrome, not a single project record. `/settings/import` stages pasted/uploaded package data for review before applying it to the draft. |
| Project source and workspace layout | `docs/workspace-source-layout-design.md`, `docs/user-guide.zh-CN.md`, `docs/long_term_direction.zh-CN.md` | 090, 091, 096, 117, 128, 216 | Project Settings own repository URL, default branch, checkout depth, source strategy, setup and cleanup commands, and optional hook overrides (a non-blank project hook replaces the workflow-level hook). Shared base roots own repository cache/worktree location. Clone/worktree setup is not a lifecycle hook. |
| Worker execution modes | `README.md`, `ARCHITECTURE.md`, `docs/persistence_and_auth.md`, `docs/worker-panel-decoupling-design.md` | 008-015, 131, 151 | Default execution is centralized. Centralized can run local Codex or remote SSH hosts. `SYMPHONY_EXECUTION_MODE=worker` uses the HTTP task queue for external workers. Worker mode is optional and not required for normal local operation. |
| Linear integration | `README.md`, `docs/user-guide.zh-CN.md`, `docs/codex-linear-interaction-design.md`, `docs/long_term_direction.zh-CN.md` | 022, 029, 033, 055, 085-088, 136, 138, 154, 215-219 | Linear token comes from environment. One Linear user, multiple project slugs: each enabled project names its own Linear project slug. Settings discovery is read-only and shared by Project/Workflow tabs. Diagnostics validates active runtime config. Codex gets restricted task tools, not raw Linear credentials. |
| GitHub PR-first implementation delivery | `docs/spec-agent-runner.md`, `docs/codex-linear-implementation-workflow-design.md`, `docs/user-guide.zh-CN.md` | active 256, 258 | Codex implements, validates, commits, and pushes the exact Linear branch, then explicitly requests `Ready to Merge`. `AgentRunner` idempotently ensures the exact open GitHub PR before final Linear writes. Human review/merge and Linear's merged-PR automation own `Ready to Merge -> Done`; Symphony has no backend merge route. |
| Observability and run history | `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md` | 054, 062, 066, 067, 103, 108, 116, 118, 133, 141, 155, 157, completed 158, 218, active 257 | Dashboard and `/api/v1/state` are memory-backed current state. Issue lookup preserves live precedence and can resolve inactive persisted issues; `/api/v1/runs` exposes bounded Repo-backed runs/events with typed failures. Persistence-backed history is isolated from workflow/orchestrator/dashboard owners. Runs/run detail/events remain persisted audit views. |
| Dashboard and analytics | `README.md`, `docs/long_term_direction.zh-CN.md` | 007, 016, 070, 130, 136, completed 158 | Dashboard, runs, workers, events, settings, diagnostics, and historical analytics exist. Future analytics enhancements should be described as extensions, not as the original Analytics page being missing. |
| Deployment and edge ownership | `README.md`, `docs/deployment.md` | 030, 031, completed 159 | Docker targets, runtime proxy env vars, trusted forwarded headers, health/readiness probes, and copyable reverse-proxy/Kubernetes deployment examples exist. Symphony still does not own public TLS/domain termination directly; that remains external edge infrastructure. |
| GitHub-facing README | root `README.md` | completed 161 | Root README is now the GitHub-style project entrypoint and should remain accurate as product/runtime behavior changes. |
| Boundary/test refactors | `design.md`, `AGENTS.md`, exec plans | 105-157, completed 162-182, completed follow-ups 195-207 | Boundary extraction and test-split work should update module maps and contributor guidance when ownership changes. Completed 176-182 established the first route/message/test boundaries; completed follow-ups cover remaining dynamic atom, settings, session-history, workspace, and test-suite ownership debt. |
| Exec-plan governance | `docs/exec-plans/README.md`, this document | 126, 160 | Completed plans must include evidence. Product/runtime doc changes should update this matrix or the canonical docs in the same PR when they change public behavior. |

## Historical Findings (Plan 160)

Historical record of stale/conflicting statements found during plan 160 and their required
updates. These were fixed in later plans; the section is retained for auditability.

| Source document | Relevant plan(s) | Stale/conflicting statement | Required update | Owner area |
| --- | --- | --- | --- | --- |
| `docs/long_term_direction.zh-CN.md` | 132 | Split package import/diff described as still missing. | Mark `/settings/import` staged paste/upload import and diff review as landed; keep export button coverage as future work. | Settings |
| `docs/workflow-page-design.md` | 132 | File upload described as a long-term upgrade. | Mark paste/upload as current behavior and keep import semantics unchanged. | Settings |
| `docs/long_term_direction.zh-CN.md` | 133, 157, completed 158 | Older text mixed live dashboard, persisted run/events, blocked sessions, and analytics. | Keep live dashboard, persisted run/events, blocked sessions, and `/analytics` as distinct shipped surfaces. | Observability |
| `README.md`, `ARCHITECTURE.md`, `docs/deployment.md` | completed 159 | Older text did not distinguish app runtime from edge TLS/domain ownership. | Keep deployment examples current while preserving that public TLS/domain termination belongs to external edge infrastructure. | Deployment |
| `README.md`, `docs/long_term_direction.zh-CN.md` | completed 161 | Older README was accurate but not the final project entrypoint. | Treat root README as the shipped GitHub-style project entrypoint and keep future roadmap details in docs/execplans. | Documentation |

## Future Plan Requirements

When a completed plan changes product behavior, update the docs in the same change:

- Runtime/config behavior: `README.md`, `docs/user-guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md`.
- Settings behavior: `docs/workflow-page-design.md`, `docs/user-guide.zh-CN.md`, and this matrix.
- Worker/deployment behavior: `README.md`, `ARCHITECTURE.md`, `docs/worker-panel-decoupling-design.md`, and deployment docs.
- Observability behavior: `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md`, and run/events docs when present.
- Public repository positioning: root `README.md`.

If a long-term document mentions active work, it must use planned wording and link the active plan.
If a completed plan supersedes older docs or plans, the completed plan should be cited by number in
the updated canonical document.
