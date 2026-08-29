---
title: Documentation Alignment Matrix
genre: meta
domain: [governance, alignment]
status: current
language: en
updated: 2026-08-28
---

# Documentation Alignment Matrix

This matrix records claim-level ownership: each long-lived topic has exactly one owning
document (single source of truth); other documents link instead of restating. It is the review
checklist for keeping product direction, architecture, and operator docs
consistent. `mix docs.check` enforces document structure; this matrix tracks claim ownership.

## Canonical Topics

| Topic | Canonical current doc | Current truth |
| --- | --- | --- |
| Runtime configuration source | `README.md`, `docs/user-guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md` | One current PostgreSQL workflow per project is durable authority. Cold start and successful mutations atomically publish one in-memory per-project/default/source snapshot; normal runtime reads never query PostgreSQL. Background refresh is single-flight, generation-guarded, and last-known-good. Split YAML files remain import/export artifacts, not runtime fallback. |
| Settings ownership | `docs/workflow-page-design.md`, `docs/long_term_direction.zh-CN.md`, `README.md` | `/settings/projects` owns project slug/repository/source strategy and per-project hook overrides. `/settings/workflow`, `/settings/agents`, `/settings/runtime` are per-project: the Settings header switcher selects which project's versions are edited, and the workflow/agents/runtime/import tabs read and save that project's records. Project selection is Settings chrome, not a single project record. `/settings/import` stages pasted/uploaded package data for review before applying it to the draft. |
| Project source and workspace layout | `docs/workspace-source-layout-design.md`, `docs/user-guide.zh-CN.md`, `docs/long_term_direction.zh-CN.md` | Project Settings own repository URL, default branch, checkout depth, source strategy, setup and cleanup commands, and optional hook overrides (a non-blank project hook replaces the workflow-level hook). Shared base roots own repository cache/worktree location. Clone/worktree setup is not a lifecycle hook. |
| Worker execution modes | `README.md`, `ARCHITECTURE.md`, `docs/persistence_and_auth.md`, `docs/worker-panel-decoupling-design.md` | Default execution is centralized. Centralized can run local Codex or remote SSH hosts. `SYMPHONY_EXECUTION_MODE=worker` uses the HTTP task queue for external workers. Worker mode is optional and not required for normal local operation. |
| External execution runtime | `docs/execution-runtime-design.md`, `docs/worker-panel-decoupling-design.md`, `docs/execution-worker-operations.md` | The opt-in `execution-worker` Compose profile deploys the non-root worker with separate storage and least-scope credentials. The Panel snapshots execution inputs and persists bounded runtime, validation, and handoff evidence. PostgreSQL remains lifecycle authority; `centralized` stays the default pending recorded operational drills. |
| Linear integration | `README.md`, `docs/user-guide.zh-CN.md`, `docs/codex-linear-interaction-design.md`, `docs/long_term_direction.zh-CN.md` | Linear token comes from environment. One Linear user, multiple project slugs: each enabled project names its own Linear project slug. Settings discovery is read-only and shared by Project/Workflow tabs. Diagnostics validates active runtime config. Codex gets restricted task tools, not raw Linear credentials. |
| GitHub PR-first implementation delivery | `docs/spec-agent-runner.md`, `docs/pull-request-body.md`, `docs/codex-linear-implementation-workflow-design.md`, `docs/user-guide.zh-CN.md` | Codex implements, validates, commits, and pushes the exact Linear branch, then calls restricted `create_pull_request` with a docs-governed title/body. `AgentRunner` owns its credential-isolated backend and idempotently ensures the exact open GitHub PR without overwriting an existing PR. Codex includes the returned URL and completion proof in the final Linear completion request. Human review/merge and Linear's merged-PR automation own `Ready to Merge -> Done`; Symphony has no backend merge route. |
| Persistent tracker blocking | `docs/spec-orchestration.md`, `docs/spec-workflow-config.md`, `docs/spec-observability.md` | `Blocked` is non-dispatchable. A durable decision gates dispatch before Symphony retries its Linear comment/state writes; human recovery clears the decision and no-progress streak. |
| Agent container-validation policy | `profiles.yml`, `docs/compose.md`, `docs/spec-workflow-config.md` | The PostgreSQL current workflow remains runtime authority, while the prompt builder enforces a non-configurable safety suffix for every refinement/implementation project prompt and `profiles.yml` carries the import/export default. Agents may statically inspect container configuration but never invoke container engines or image operations. Required prohibited validation persists blocker evidence and fails closed through `blocking_decision` / `Blocked`; allowed ticket validation remains mandatory. |
| Observability and run history | `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md` | Dashboard and `/api/v1/state` are memory-backed current state. Issue lookup preserves live precedence and can resolve inactive persisted issues; `/api/v1/runs` exposes bounded Repo-backed runs/events with typed failures. Runs and worker task views project persisted bounded validation/runtime/handoff evidence; worker-local paths are never displayed. |
| Dashboard and analytics | `README.md`, `docs/long_term_direction.zh-CN.md` | Dashboard, runs, workers, events, settings, diagnostics, and historical analytics exist. Future analytics enhancements should be described as extensions, not as the original Analytics page being missing. |
| Deployment and image ownership | `docs/compose.md`, `README.md`, `docs/deployment.md`, `docs/execution-worker-operations.md` | Root Compose runs PostgreSQL, migration, and Panel services plus an opt-in trusted HTTP execution worker profile. `docs/compose.md` owns the rule that migration, Panel, and execution worker have no engine CLI/socket, privileged mode, daemon, nested Compose, or container-management surface. Root Compose defaults to building `symphony:local`; its published-image override pulls one selected immutable GHCR multi-architecture (amd64/arm64) image for both migration and application services. The shared Docker stage pins Codex CLI `0.150.1` for all runtime and worker targets; `codex_home` remains a named volume across image recreation. The Symphony image owns token-free system Git configuration: GitHub HTTPS authentication uses `gh auth git-credential`, and GitHub SCP-style SSH URLs rewrite to plain HTTPS. Fresh workspace volumes need no credential seeding; service bootstrap and PR handoff retain GitHub token environment while Codex children do not. GitHub Actions owns image build, image-level verification, and amd64/arm64 publication with manifest smoke checks. Host operators own Compose deployment operations. Panel and worker are non-root, least-capability, separately stored/networked; the worker cannot join the database network. Runtime proxy env vars, trusted forwarded headers, health/readiness probes, and reverse-proxy/Kubernetes examples remain supported. Public TLS/domain termination and production worker egress filtering remain external edge infrastructure. |
| PostgreSQL persistence and SQLite cutover | `docs/persistence_and_auth.md`, `docs/compose.md`, `docs/test_database_isolation.md` | PostgreSQL/postgrex is the only runtime backend and `DATABASE_URL` is the application contract. SQLite is a stopped backup import source only. Default tests are database-free; the explicit PostgreSQL smoke owns migration/import/concurrent-write evidence. |
| GitHub-facing README | root `README.md` | Root README is now the GitHub-style project entrypoint and should remain accurate as product/runtime behavior changes. |
| Boundary/test refactors | `design.md`, `AGENTS.md` | Boundary extraction and test-split work should update module maps and contributor guidance when ownership changes. |

## Documentation Update Requirements

When implementation changes product behavior, update the docs in the same change:

- Runtime/config behavior: `README.md`, `docs/user-guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md`.
- Settings behavior: `docs/workflow-page-design.md`, `docs/user-guide.zh-CN.md`, and this matrix.
- Worker/deployment behavior: `README.md`, `ARCHITECTURE.md`, `docs/worker-panel-decoupling-design.md`, and deployment docs.
- Observability behavior: `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md`, and run/events docs when present.
- Public repository positioning: root `README.md`.

Future intent belongs in an L3 design with an explicit status. Current behavior belongs in its
canonical owner and should link to reviewable implementation where delivery evidence is useful.
