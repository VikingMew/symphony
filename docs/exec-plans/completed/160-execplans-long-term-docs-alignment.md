# 160 Exec Plans and Long-Term Documentation Alignment

## Goal

Align all exec plans with the project's long-term documentation so the planning archive, product direction, architecture docs, user docs, and deployment docs describe the same system.

The outcome should be a coherent documentation set where completed work, active plans, and long-term direction do not contradict each other.

## Status

Completed.

## Background

Symphony now has a large exec-plan archive and multiple long-lived documentation sources:

- root `README.md`, `ARCHITECTURE.md`, `SPEC.md`, `CODE_STRUCTURE.md`;
- `elixir/README.md`, `elixir/AGENTS.md`;
- `elixir/docs/long_term_direction.zh-CN.md`;
- user/deployment/workflow docs under `elixir/docs/`;
- 150+ exec plans under `elixir/docs/exec-plans/`.

Recent work changed major product and runtime contracts:

- database-first runtime configuration;
- split settings package import/export;
- worktree source strategy;
- run detail, events, dashboard, and analytics direction;
- Linear health signals and diagnostics;
- input-required blocked sessions;
- reverse proxy / Kubernetes deployment;
- orchestrator and module-boundary refactors.

The long-term docs may lag behind completed exec plans, while some active exec plans may repeat, supersede, or contradict older long-term direction. Operators and future agents need a single coherent understanding of what is true now, what is planned, and what is intentionally deprecated.

## Scope

- Audit completed and active exec plans against long-term docs.
- Identify contradictions, stale statements, missing concepts, and duplicated guidance.
- Produce a documentation alignment matrix covering:
  - source document;
  - relevant exec plan(s);
  - current truth;
  - stale/conflicting statement;
  - required doc update;
  - owning area.
- Update long-lived docs so they reflect completed plans and current active direction.
- Add references from long-term docs to active exec plans where behavior is intentionally planned but not implemented.
- Clarify deprecated concepts:
  - local workflow files as runtime source;
  - standalone raw workflow editing as primary UI;
  - worker mode vs SSH centralized workers;
  - dashboard live state vs persisted historical analytics;
  - TLS/domain ownership vs reverse proxy/Kubernetes deployment.
- Ensure exec plan README/index rules remain valid.
- Add guidance for future plans:
  - when a completed plan changes product direction, which long-term docs must be updated;
  - what evidence is required before moving UI/runtime plans to completed;
  - how to mark a plan as superseding older docs or older plans.

## Out of Scope

- Do not implement product/runtime code changes.
- Do not rewrite every document from scratch.
- Do not delete historical exec plans.
- Do not hide unresolved contradictions; record them and link active follow-up plans.
- Do not translate every English document into Chinese or vice versa unless a specific doc already requires it.

## Acceptance Criteria

- Long-term docs no longer contradict completed exec plans on runtime source, Settings ownership, worker modes, dashboard/run/events observability, and deployment ownership.
- Active exec plans that describe future behavior are referenced as planned work, not documented as already delivered.
- Deprecated behavior is clearly labelled as deprecated or historical.
- A documentation alignment matrix exists and is committed.
- The exec-plan README remains indexed and passes `mix exec_plans.check`.
- Documentation updates include enough cross-links for future agents to find the owning plan.
- Reviewers can tell which docs are canonical for:
  - runtime configuration;
  - deployment;
  - workflow/profile settings;
  - Linear integration;
  - observability/analytics;
  - worker execution modes.

## Test Cases

- Search for runtime-source claims:
  - docs consistently say database active workflow is runtime truth;
  - local `workflow.yml` / `profiles.yml` are import/export artifacts unless explicitly marked as fixtures/examples.
- Search for worker-mode claims:
  - docs distinguish centralized local/SSH execution from HTTP worker queue mode.
- Search for deployment claims:
  - docs say Nginx/Kubernetes can own TLS/domain once plan 159 is implemented or mark it as planned while active.
- Search for dashboard/run/events claims:
  - docs distinguish live dashboard, run detail, events audit, and planned analytics.
- Search for Settings import claims:
  - docs distinguish existing behavior from planned staged import review page if active.
- Run exec plan index checker:
  - `mix exec_plans.check` passes.

## Implementation Notes

Start with an inventory rather than editing opportunistically.

Recommended workflow:

1. Build a list of long-lived docs and their owning topics.
2. Sample all completed plans from 080 onward plus active plans, because these contain the most recent product direction.
3. Create an alignment matrix, likely under `elixir/docs/`, for example:

```text
elixir/docs/documentation_alignment.md
```

4. Update stale docs in focused patches.
5. Keep historical exec plans unchanged except for index consistency.
6. Add "planned" vs "implemented" wording where active exec plans are referenced.

Prefer concrete links to plan numbers instead of vague statements like "recent work changed this."

When conflicts exist between completed plans and long-term docs, completed code-backed plans should usually win. When conflicts exist between active plans and completed docs, long-term docs should say the behavior is planned and link the active plan.

## Verification

- `rg -n "workflow(_| )?file|workflow\\.yml.*runtime|profiles\\.yml.*runtime|startup.*workflow\\.yml|fallback source|auto seed|raw textarea|巨大纯文本框|只有 raw|file upload|长期可以升级为文件上传|Analytics.*已|/analytics|Kubernetes.*已|Nginx.*已|TLS.*已" README.md docs/*.md ../README.md ../ARCHITECTURE.md ../SPEC.md ../CODE_STRUCTURE.md`
- Manual review and focused updates:
  - root `README.md`;
  - root `ARCHITECTURE.md`;
  - `elixir/README.md`;
  - `elixir/AGENTS.md`;
  - `elixir/docs/long_term_direction.zh-CN.md`;
  - `elixir/docs/workflow_page_design.zh-CN.md`;
  - new `elixir/docs/documentation_alignment.md`.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

Root `SPEC.md` was reviewed by targeted search but not rewritten. Its package-file language is implementation-agnostic and already says packages are not startup authority unless imported into the datastore, so changing it would add churn without improving alignment.

Root `README.md` remains concise. The broader GitHub-style rewrite is intentionally left to active plan 161.

## Dependencies

- Completed exec-plan archive through 157.
- Active plan 158 for runtime analytics.
- Active plan 159 for reverse proxy/Kubernetes deployment.
- Existing long-term docs under root and `elixir/docs/`.

## Handoff Notes

This is documentation governance work. The goal is not to make docs longer; it is to make them reliable. Prefer fewer canonical statements with links to owning plans over repeated stale explanations.
