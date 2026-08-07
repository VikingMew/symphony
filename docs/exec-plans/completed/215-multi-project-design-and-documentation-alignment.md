# 215 Multi-Project Design & Documentation Alignment

## Goal

Update every design and documentation surface that describes Symphony's project model so the
repository's written intent matches the multi-project runtime planned in 216-219. This plan is a
documentation ledger: it lists every file that must change, what changes in each, and the order in
which they depend on the implementation plans.

## Status

Completed.

## Background

The runtime today is single-project: one active workflow version (the default project), one
`tracker.project_slug`, one global `hooks` block, and a scheduler that only polls one Linear
project. The data layer already persists multiple projects, but the written design still describes
the single-project model.

Plans 216-219 will make the runtime multi-project (per-project workflow cache, per-project hooks,
orchestrator dispatch over enabled projects, UI filtering, settings switching). Before and during
those changes, the design documents must be brought in line so implementers and operators do not
read stale single-project intent.

This plan does not implement runtime behavior. It inventories the documentation surface, states
what each file must say after the multi-project work lands, and records which implementation plan
each doc change rides with.

## Scope

Inventory and update the following documentation. For each file: the change, and the plan whose
landing it should ride with (per AGENTS.md, docs update in the same change where practical).

### A. Core design documents (must change)

1. `SPEC.md` — language-agnostic service specification. Currently single-project:
   - `5.3 Front Matter Schema`: `tracker.project_slug` is a single string; `hooks` is a global
     workflow-level object.
   - `6.4 Core Config Fields`: `tracker.project_slug` REQUIRED for linear.
   - `8.1 Poll Loop` / `8.2 Candidate Selection`: one poll loop, one project slug filter.
   - `9.4 Workspace Hooks`: hooks are workflow-level.
   - Change: describe one active workflow version **per project**, poll/dispatch iterating
     enabled projects, hooks overridable per project (workflow default + project overlay), and
     `project_id` binding on runs/issues/events.
   - Rides with: 216 (runtime store), then corrected by 217 (dispatch) where behavior lands.

2. `ARCHITECTURE.md` — implementation architecture. Currently single-workflow:
   - `5. Runtime Flow`: single workflow load -> orchestrator -> dispatch chain.
   - Module notes: `SymphonyElixir.WorkflowStore` as single workflow cache; tracker layer
     described in singular.
   - Change: WorkflowStore caches enabled projects' workflows; orchestrator iterates projects;
     workspace isolation per repository; observability filtered by project.
   - Rides with: 216.

3. `README.md` (root) — GitHub entrypoint. Currently:
   - `Core Concepts` table defines Project singularly and Workflow as one runtime policy.
   - Quick Start / Settings steps describe one project.
   - Change: state that Symphony can maintain multiple projects concurrently (one Linear project +
     one repository each, shared Linear user, per-project workflow + hooks), and that Settings and
     observability pages are project-aware.
   - Rides with: 218 (settings), 217 (filtering).

4. `CODE_STRUCTURE.md` and `CODE_STRUCTURE.zh-CN.md` — module tables:
   - `SymphonyElixir.WorkflowStore`: "Keeps current workflow state" -> "caches active workflows
     for enabled projects".
   - `SymphonyElixir.Persistence`: already lists projects; confirm it mentions per-project
     workflow versions and project-scoped run/issue records.
   - Rides with: 216.

5. `elixir/README.md` — Elixir implementation guide:
   - Configure step: Settings now includes project selection/filtering.
   - `workflow.yml` example comment: the split file is an import/export artifact; per-project
     workflow versions are the runtime authority; hooks may be overridden per project.
   - Rides with: 216/218.

### B. Operational and design notes (should change)

6. `elixir/docs/documentation_alignment.md` — the long-lived documentation ownership ledger. Per
   its own rules (and AGENTS.md), any change to runtime source, Settings ownership, worker modes,
   observability/analytics, or Linear integration must update this file. Rows to update:
   - `Settings ownership` row: `/settings/workflow` becomes per-project; project selection
     belongs to Settings chrome, not to a single project record.
   - `Project source and workspace layout` row: hooks may be overridden per project.
   - `Linear integration` row: one Linear user, multiple project slugs.
   - `GitHub-facing README` row: README claims multi-project behavior.
   - Rides with: each implementation plan updates its rows; final sweep in 219.

7. `elixir/docs/long_term_direction.zh-CN.md` — long-term direction and landed-status ledger:
   - `5.1 projects` and Settings evolution sections: update to multi-project runtime
     (per-project workflow versions, project switching, project filter).
   - Rides with: 216/217/218 as each lands; final sweep in 219.

8. `elixir/docs/user_guide.zh-CN.md` — operator guide:
   - Project settings section: multiple projects, enable/disable, per-project Linear slug +
     repository + hooks.
   - Workflow settings section: per-project workflow versions and switching.
   - Observability section: project filters on Runs/Issues/Events/Workers/Analytics.
   - Rides with: 217/218.

9. `elixir/docs/workflow_page_design.zh-CN.md` — workflow page design note:
   - Add project switching to the workflow page design.
   - Rides with: 218.

10. `elixir/docs/worker_panel_decoupling_design.zh-CN.md` — worker panel design:
    - Worker tasks/runs now carry project scope; panel lists project for each task.
    - Rides with: 217.

11. `elixir/docs/workspace_source_layout.zh-CN.md` — workspace layout note:
    - Repository cache/worktree isolation already hashes per repository; state that this
      isolation is what keeps multiple projects' workspaces separate.
    - Rides with: 216.

12. `elixir/docs/persistence_and_auth.md` — persistence note:
    - Confirm projects table, per-project workflow versions, and `project_id` on
      runs/issues/events/tasks are described.
    - Rides with: 216.

### C. Sample/artifact files (review, likely minor)

13. `elixir/workflow.yml` — import/export example. Add a comment that the runtime authority is the
    active per-project workflow version and hooks may be overridden per project. No structural
    change to the sample itself.
    - Rides with: 216.

14. `elixir/profiles.yml` — profiles example. Unchanged unless profile semantics become
    per-project, which is not planned. No change expected.

### D. Not changed (verified)

- `elixir/docs/deployment.md` — single deployment instance serves all projects; no change.
- `elixir/docs/logging.md`, `token_accounting.md`, `test_database_isolation.md`,
  `hot_update.zh-CN.md`, `dashboard_color_system_design.zh-CN.md`,
  `codex_linear_interaction.zh-CN.md`, `codex_linear_task_refinement_workflow.zh-CN.md`,
  `codex_linear_implementation_workflow.zh-CN.md` — no project-model claims that conflict with
  multi-project runtime.
- `LICENSE`, `NOTICE`, `.github/pull_request_template.md` — no change.
- `elixir/docs/exec-plans/README.md` — index; updated only by the usual completed-plan sweep.

## Out of Scope

- Implementing runtime behavior (plans 216-219).
- Rewriting documentation prose wholesale; only project-model claims change.
- Translating new prose into zh-CN for documents that do not already have a zh-CN twin.

## Acceptance Criteria

- Every file in sections A and B has a tracked change (either in this plan's sweep or riding with
  its implementation plan).
- After 216-219 land, a reader of `SPEC.md`, `ARCHITECTURE.md`, root `README.md`, and
  `elixir/README.md` understands that one Symphony instance maintains multiple projects with
  per-project workflow versions and hooks.
- `documentation_alignment.md` rows reflect the new Settings ownership and project-scoped
  observability.
- `user_guide.zh-CN.md` describes adding/editing/disabling projects and filtering by project.
- No document in section D was touched.

## Test Cases

Documentation plans are verified by review, not unit tests:

- Grep check: after landing, `grep -c "project" SPEC.md` still meaningful; spot-check that
  `tracker.project_slug` singular claims appear only where a per-project tracker is described.
- Cross-check: every file listed in `documentation_alignment.md` for Settings ownership / Linear
  integration / observability rows has matching claims in the docs it names.
- Review: diff of each doc change is limited to project-model claims (no unrelated prose edits).

## Implementation Notes

- Write the multi-project model once in `SPEC.md` (normative), mirror the claim in
  `ARCHITECTURE.md` and `README.md`, then propagate to operational docs.
- Keep the doc sweep in lockstep with implementation plans: 216 lands with SPEC/ARCHITECTURE/
  CODE_STRUCTURE/elixir-README/workspace-layout/persistence-and-auth edits; 217 lands with
  README/observability rows; 218 lands with Settings rows and workflow-page/user-guide edits;
  a final sweep in 219 re-checks `documentation_alignment.md` and `long_term_direction.zh-CN.md`.
- zh-CN docs: edit the zh-CN file when the corresponding English file changes; keep them in sync.

## Verification

- `mise exec -- mix exec_plans.check` (this plan and 216-219 must pass).
- Manual review of each doc diff.
- `make all` still passes (docs-only plan; confirms nothing else broke).

- Closed with plan 219 (multi-project line complete). Final gate state after plans 221-224: 664 tests / 0 failures, format + specs pass, credo 0 `[F]`, dialyzer 0 warnings, exec_plans.check pass.

## Completion Deviations

- Doc sweep finished by plan 219 (zh-CN docs updated; root/elixir READMEs and documentation_alignment verified clean).

## Dependencies

- No implementation dependencies; this plan precedes 216-219 and its sweep continues through them.

## Handoff Notes

The trap to avoid is treating documentation as a single end-of-project task. The AGENTS.md rule is
"update docs in the same change where practical." Each implementation plan 216-219 must name the
doc rows it updates; this plan is the authoritative inventory so implementers do not miss one.
