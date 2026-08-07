# 225 Documentation Meta-System

## Goal

Establish the documentation meta-system defined in
`elixir/docs/documentation-system-design.md`: the L0-L5 layer model becomes written
law, a navigation index exists, a decision log starts, and `mix docs.check` provides
machine verification for document structure — before any physical reorganization.

## Status

Active.

## Background

Plans 215-224 fixed code and quality gates; the documentation itself has no
classification system, no authority layering, and no verification hook (only
`exec_plans.check` exists). The design doc (referenced above, modeled on
letsinflu-server's L0-L5 layer system) defines the target: flat docs/ + conceptual
layers + naming conventions + frontmatter + a check tool. This plan builds the
meta-layer in place (no file moves yet — those are plans 226/227).

## Scope

- Add a "Documentation Layers" section to `elixir/AGENTS.md`: the L0-L5 model,
  single-source-of-truth rule ("each contract has exactly one owning document; other
  documents link, not restate"), and the rule that new documents must be placed in
  exactly one layer.
- Create `elixir/docs/README.md`: navigation index listing every current document with
  its layer assignment (from the design doc's layer table).
- Create `elixir/docs/decisions.md`: ADR-style decision log; record existing decisions
  (Elixir/Phoenix control plane, SQLite runtime settings, per-project workflow
  versions, exec-plan lifecycle, dialyzer/credo debt cleanup, elixir/ promotion
  decision, documentation layer model).
- Create `mix docs.check` (Elixir mix task, `lib/mix/tasks/docs.check.ex`): validates,
  for each `.md` under `docs/` (excluding `exec-plans/`):
  - frontmatter present and parseable; `genre` in the allowed set; `status` legal
  - `docs/README.md` index registration (filename listed)
  - `owner` anchor exists (module or function name found under `lib/`) when genre is
    reference/spec
  - fails with a readable per-document report; exits non-zero on any violation
- Add frontmatter to 5 representative documents as the seed set: `token_accounting.md`
  (reference), `logging.md` (spec), `deployment.md` (guide), `user_guide.zh-CN.md`
  (guide), `workflow_page_design.zh-CN.md` (design).
- Update `documentation-system-design.md` status `proposed` -> `landed` at the end.

## Out of Scope

- Physical file moves / elixir/ promotion (plans 226-227).
- Full frontmatter sweep of every document (plan 227).
- SPEC.md split (evaluated in plan 227).
- CODE_STRUCTURE merge / zh-CN removal (plan 227).

## Acceptance Criteria

- `mise exec -- mix docs.check` passes on the seed set and reports clean.
- `elixir/AGENTS.md` contains the layer model + single-source-of-truth rule.
- `elixir/docs/README.md` lists every current document with a layer assignment.
- `elixir/docs/decisions.md` records at least 4 prior decisions in ADR format.
- `mix docs.check` fails loudly on a deliberately broken frontmatter (verified in test).

## Test Cases

- Run `mix docs.check` -> exit 0, all seed docs pass.
- Temporarily corrupt one frontmatter (bad genre) -> exit non-zero, names the file.
- `mix exec_plans.check` still passes (plan registered in index).
- `mix test` unaffected (mix task addition only) — spot check compile.

## Implementation Notes

- The mix task is small (~80 lines): parse frontmatter with a regex split on `---`,
  validate fields, grep index and anchors. Keep it dependency-free.
- Layer table in docs/README.md mirrors the design doc's table; add a "pending 227"
  note where physical targets differ from current paths.
- decisions.md entries: one `### <title>` + `Status: accepted` + 2-4 line rationale
  each; backfill from session history (215-224) — do not invent new decisions.

## Verification

- `mise exec -- mix docs.check`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix exec_plans.check`
- `mise exec -- mix test` (664 expected, 0 failures)

## Completion Deviations

- To be filled after implementation.

## Dependencies

- Design: `elixir/docs/documentation-system-design.md` (this plan implements it).
- No code dependencies; 226/227 consume this plan's outputs.

## Handoff Notes

Documentation-heavy plan — executed by the reviewer (Hermes) directly, not Codex.
The mix task is the only code; keep it minimal and dependency-free. Do NOT move any
files (226 owns that). Frontmatter seed set is 5 documents only — full sweep is 227.
