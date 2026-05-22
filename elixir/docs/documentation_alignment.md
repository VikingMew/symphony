# Documentation Alignment Matrix

This matrix records how long-lived documentation maps to the exec-plan archive. It is the review
checklist for keeping product direction, architecture, operator docs, and active plans consistent.

## Canonical Topics

| Topic | Canonical current doc | Owning plans | Current truth |
| --- | --- | --- | --- |
| Runtime configuration source | `README.md`, `docs/user_guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md` | 080, 097, 119, 120, 152 | Runtime reads the SQLite active workflow version. `workflow.yml` and `profiles.yml` are import/export package artifacts and examples, not startup authority or fallback source. Empty DB starts in setup-required and does not listen or dispatch. |
| Settings ownership | `docs/workflow_page_design.zh-CN.md`, `docs/long_term_direction.zh-CN.md`, `README.md` | 077, 081-089, 132, 140 | `/settings/projects` owns project slug/repository/source strategy. `/settings/workflow` owns shared workflow/routing/runtime policy. `/settings/agents` owns base prompt/profiles/allowed updates. `/settings/import` stages pasted/uploaded package data for review before applying it to the draft; runtime changes only after normal save. |
| Split package import/export | `README.md`, `docs/user_guide.zh-CN.md`, `docs/workflow_page_design.zh-CN.md` | 075, 076, 098, 132 | Split packages are data exchange artifacts. Import supports paste and upload, auto-detects package type from YAML fields, shows diff/review, and applies to the editable draft only after confirmation. Export/button coverage is still incomplete and should be described as future work where mentioned. |
| Project source and workspace layout | `docs/workspace_source_layout.zh-CN.md`, `docs/user_guide.zh-CN.md`, `docs/long_term_direction.zh-CN.md` | 090, 091, 096, 117, 128 | Project Settings own repository URL, default branch, checkout depth, source strategy, setup and cleanup commands. Shared base roots own repository cache/worktree location. Clone/worktree setup is not a lifecycle hook. |
| Worker execution modes | `README.md`, `ARCHITECTURE.md`, `docs/persistence_and_auth.md`, `docs/worker_panel_decoupling_design.zh-CN.md` | 008-015, 131, 151 | Default execution is centralized. Centralized can run local Codex or remote SSH hosts. `SYMPHONY_EXECUTION_MODE=worker` uses the HTTP task queue for external workers. Worker mode is optional and not required for normal local operation. |
| Linear integration | `README.md`, `docs/user_guide.zh-CN.md`, `docs/codex_linear_interaction.zh-CN.md`, `docs/long_term_direction.zh-CN.md` | 022, 029, 033, 055, 085-088, 136, 138, 154 | Linear token comes from environment. Settings discovery is read-only and shared by Project/Workflow tabs. Diagnostics validates active runtime config. Codex gets restricted task tools, not raw Linear credentials. |
| Observability and run history | `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md` | 054, 062, 066, 067, 103, 108, 116, 118, 133, 141, 155, 157, completed 158 | Dashboard is live operational state. Runs/run detail/events are persisted history and audit. Blocked input-required sessions are visible in snapshot/API/dashboard and are not ordinary retry failures. `/analytics` is the shipped time-range historical analytics page. |
| Dashboard and analytics | `README.md`, `docs/long_term_direction.zh-CN.md` | 007, 016, 070, 130, 136, completed 158 | Dashboard, runs, workers, events, settings, diagnostics, and historical analytics exist. Future analytics enhancements should be described as extensions, not as the original Analytics page being missing. |
| Deployment and edge ownership | `README.md`, `docs/deployment.md` | 030, 031, completed 159 | Docker targets, runtime proxy env vars, trusted forwarded headers, health/readiness probes, and copyable reverse-proxy/Kubernetes deployment examples exist. Symphony still does not own public TLS/domain termination directly; that remains external edge infrastructure. |
| GitHub-facing README | root `README.md` | completed 161 | Root README is now the GitHub-style project entrypoint and should remain accurate as product/runtime behavior changes. |
| Boundary/test refactors | `CODE_STRUCTURE.md`, `AGENTS.md`, exec plans | 105-157, completed 162-182, completed follow-ups 195-207 | Boundary extraction and test-split work should update module maps and contributor guidance when ownership changes. Completed 176-182 established the first route/message/test boundaries; completed follow-ups cover remaining dynamic atom, settings, session-history, workspace, and test-suite ownership debt. |
| Exec-plan governance | `docs/exec-plans/README.md`, this document | 126, 160 | Completed plans must include evidence. Product/runtime doc changes should update this matrix or the canonical docs in the same PR when they change public behavior. |

## Stale Or Conflicting Statements Found In Plan 160

| Source document | Relevant plan(s) | Stale/conflicting statement | Required update | Owner area |
| --- | --- | --- | --- | --- |
| `docs/long_term_direction.zh-CN.md` | 132 | Split package import/diff described as still missing. | Mark `/settings/import` staged paste/upload import and diff review as landed; keep export button coverage as future work. | Settings |
| `docs/workflow_page_design.zh-CN.md` | 132 | File upload described as a long-term upgrade. | Mark paste/upload as current behavior and keep import semantics unchanged. | Settings |
| `docs/long_term_direction.zh-CN.md` | 133, 157, completed 158 | Older text mixed live dashboard, persisted run/events, blocked sessions, and analytics. | Keep live dashboard, persisted run/events, blocked sessions, and `/analytics` as distinct shipped surfaces. | Observability |
| `README.md`, `ARCHITECTURE.md`, `docs/deployment.md` | completed 159 | Older text did not distinguish app runtime from edge TLS/domain ownership. | Keep deployment examples current while preserving that public TLS/domain termination belongs to external edge infrastructure. | Deployment |
| `README.md`, `docs/long_term_direction.zh-CN.md` | completed 161 | Older README was accurate but not the final project entrypoint. | Treat root README as the shipped GitHub-style project entrypoint and keep future roadmap details in docs/execplans. | Documentation |

## Future Plan Requirements

When a completed plan changes product behavior, update the docs in the same change:

- Runtime/config behavior: `README.md`, `docs/user_guide.zh-CN.md`, `docs/persistence_and_auth.md`, `docs/long_term_direction.zh-CN.md`.
- Settings behavior: `docs/workflow_page_design.zh-CN.md`, `docs/user_guide.zh-CN.md`, and this matrix.
- Worker/deployment behavior: `README.md`, `ARCHITECTURE.md`, `docs/worker_panel_decoupling_design.zh-CN.md`, and deployment docs.
- Observability behavior: `README.md`, `ARCHITECTURE.md`, `docs/long_term_direction.zh-CN.md`, and run/events docs when present.
- Public repository positioning: root `README.md`.

If a long-term document mentions active work, it must use planned wording and link the active plan.
If a completed plan supersedes older docs or plans, the completed plan should be cited by number in
the updated canonical document.
