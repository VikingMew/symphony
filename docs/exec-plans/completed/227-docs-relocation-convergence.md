# 227 Documentation Relocation and Convergence

## Goal

After plan 226 promotes `elixir/` to root, reorganize `docs/` to match the layer model
in `docs/documentation-system-design.md`: rename documents to convention, assign every
document a layer + frontmatter, purge `elixir/`-prefix references inside docs, merge
CODE_STRUCTURE into `design.md`, and decide the SPEC split. End state: `mix docs.check`
green across ALL documents.

## Status

Completed.

## Background

Plan 225 built the meta-system (layer model, index, decisions log, `docs.check`) and
seeded frontmatter on 5 documents. Plan 226 moved everything to root. This plan
finishes the sweep: every document gets a layer and valid frontmatter, naming follows
the convention, stale paths die, and the content convergence items from the design doc
(§3, §8) land.

## Scope

- Naming normalization in `docs/`:
  - Rename feature designs to `<concern>-design.md`: `workflow_page_design.zh-CN.md`,
    `worker_panel_decoupling_design.zh-CN.md`, `workspace_source_layout.zh-CN.md`,
    `codex_linear_interaction.zh-CN.md`,
    `codex_linear_implementation_workflow.zh-CN.md`,
    `codex_linear_task_refinement_workflow.zh-CN.md`,
    `dashboard_color_system_design.zh-CN.md`, `hot_update.zh-CN.md` (language suffix
    moves into frontmatter `language:` per convention).
  - `user_guide.zh-CN.md` -> `user-guide.zh-CN.md`; keep `deployment.md`,
    `logging.md`, `token_accounting.md`, `persistence_and_auth.md`,
    `test_database_isolation.md`, `long_term_direction.zh-CN.md` (frontmatter labels
    them; roadmap genre for long_term_direction).
- Path cleanup: replace all `elixir/docs/`, `elixir/lib/`, `elixir/...` references
  inside `docs/**` (and root AGENTS.md / README.md) with root-relative paths; grep
  must return zero matches.
- Merge CODE_STRUCTURE: fold its repository-layout content into `docs/design.md`
  (create `design.md` as L2 with package layout + conventions + Feature Design
  Index); delete `docs/CODE_STRUCTURE.md` and `docs/CODE_STRUCTURE.zh-CN.md` (the
  zh-CN duplicate dies per the no-dual-docs language rule; its unique content is
  folded into design.md).
- SPEC split: evaluate splitting `SPEC.md` (2184 lines) by domain (runtime /
  orchestrator / linear / codex / web) — produce a split proposal document
  `docs/spec-split-proposal.md` with file boundaries and cross-reference plan; if the
  split is trivially mechanical (clear section boundaries), perform it, else record
  the proposal for a follow-up plan.
- Frontmatter sweep: every `.md` under `docs/` (excluding `exec-plans/`) gets valid
  frontmatter (genre/domain/status/language/owner/updated) and a layer assignment in
  `docs/README.md`.
- `documentation-alignment.md` (renamed from `documentation_alignment.md`): rewrite as
  the ongoing consistency matrix (canonical topics -> owning document), replacing the
  stale "Plan 160" historical format.
- Update `docs/documentation-system-design.md` status: landed; update layer table to
  final paths.

## Out of Scope

- The SPEC split itself if non-mechanical (proposal only; follow-up plan).
- Content rewrites beyond the convergence items above (no prose modernization).
- `docs/exec-plans/` internals (historical records; README index links updated only if
  paths change).

## Acceptance Criteria

- `mise exec -- mix docs.check` passes for ALL documents (every .md has valid
  frontmatter, genre legal, registered in docs/README.md index, owner anchors exist).
- `grep -rn "elixir/" docs/ AGENTS.md README.md` -> zero matches.
- No `CODE_STRUCTURE*.md` remains; `design.md` contains the layout + Feature Design
  Index.
- SPEC split: proposal document exists; if performed, SPEC.md is gone and sub-specs
  pass docs.check.
- `mise exec -- mix test` -> 664/0/2; `mise exec -- mix exec_plans.check` passes.

## Test Cases

- `mix docs.check` green; break one frontmatter -> red (already covered by 225, rerun).
- Grep sweep for `elixir/` in docs/AGENTS.md/README.md -> empty.
- Rename audit: every `-design.md` file has one concern; docs/README.md index matches
  `ls docs/*.md` one-to-one.

## Implementation Notes

- Run `git mv` for renames to preserve history.
- Frontmatter sweep is bulk but mechanical: assign genre from the layer table, owner
  from the document's subject module (e.g. token_accounting -> TokenUsage module).
- docs/README.md becomes the single index; keep it sorted by layer then name.
- The Feature Design Index in design.md links every `-design.md` with a one-line
  subject + `design_status` (landed/partial/proposed).

## Verification

Executed by the reviewer (Hermes) directly (documentation-heavy plan):

- Naming normalization: 8 feature designs renamed to `<concern>-design.md`; `user_guide.zh-CN.md`
  -> `user-guide.zh-CN.md`; `documentation_alignment.md` -> `documentation-alignment.md` (git mv,
  history preserved).
- SPEC split: `SPEC.md` (2184 lines) split into `spec.md` (overview + domain navigation) and 8
  domain contracts (domain-model, workflow-config, orchestration, agent-runner, linear-integration,
  observability, reliability-security, conformance). All "Section N.N" cross-references rewired to
  cross-file links; in-file references preserved. External references in AGENTS.md / README.md
  updated.
- CODE_STRUCTURE merge: `design.md` created (L2) with repository layout, package conventions,
  module map, routes, mix tasks, and a **Feature Design Index**; `CODE_STRUCTURE.md` and
  `CODE_STRUCTURE.zh-CN.md` deleted (zh-CN duplicate removed per language rule).
- Frontmatter sweep: all 30 documents under `docs/` (excluding `exec-plans/`) carry valid
  frontmatter with layer registration in `docs/README.md` (rewritten as the L0-L5 index).
- `documentation-alignment.md` rewritten as the claim-level consistency matrix (canonical topic
  -> owning document); Plan-160 findings retained as a historical section.
- `documentation-system-design.md` layer table + migration status updated to the landed state.
- Gates: `mix docs.check` -> **30 passed, 0 skipped, 0 failed**; `mix test` -> 664/0/2;
  `mix format --check-formatted` pass; `mix specs.check` pass; `mix compile --warnings-as-errors`
  pass; credo 0 `[F]`; `mix exec_plans.check` pass. Old filename references across docs: zero
  remaining.

## Completion Deviations

- **docs.check bug fixed**: `String.split(content, ~r/\R/)` matched U+0085 (NEL), which occurs
  inside UTF-8 multi-byte characters (e.g. "配" = E9 85 8D), splitting them and crashing on any
  Chinese document containing such bytes (hit on `dashboard-color-system-design.md`). Changed to
  `~r/\r?\n/` with a comment; 225's checker now handles CJK frontmatter.
- SPEC split produced 9 files (plan anticipated ~7): §11 Linear and §13 Observability each kept
  their own contract for cohesion.
- `grep "elixir/"` finds 6 remaining mentions, all intentional historical/decision prose, not
  path anchors: ARCHITECTURE.md (plan-226 reference), documentation-system-design.md (migration
  history, 4), decisions.md (ADR title). All `elixir/lib`, `elixir/docs` style path anchors are
  gone.

## Dependencies

- Plans 225 (meta-system + docs.check) and 226 (root layout) complete.

## Handoff Notes

Documentation-heavy plan — executed by the reviewer (Hermes), not Codex. The SPEC
split is the only judgment-heavy item: if section boundaries are unclear, write the
proposal and defer. Renames must use `git mv`. Do NOT touch `docs/exec-plans/` plan
content; only fix links if a referenced path changed. Run the greps before declaring
done.
