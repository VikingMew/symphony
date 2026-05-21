# 104 Project Fragment Audit and Consistency Debt

## Goal

Consolidate the current documentation/code fragments into a coherent maintenance plan. This plan records every inconsistency and technical-debt item found during the repository audit, without changing code or existing documentation in this pass.

## Status

Completed.

## Background

The repository has moved from an upstream preview shape into a Phoenix/SQLite-backed Elixir control plane. Several documents and package artifacts still describe earlier phases: file-backed workflow startup, raw Linear GraphQL tools, `reject` approval-policy maps, and the long `Needs Implementation Review` state name. Current code and tests show that the intended runtime is database-first, uses restricted Linear task tools, normalizes old `reject` approval-policy maps to `never`, and validates Linear state names against a 25-character limit.

This audit used static repository inspection plus one local schema parse check. No existing code or documentation was modified.

## Findings

### P0: The bundled workflow package is invalid under the current schema

Evidence:

- `workflow.yml` still uses `Needs Implementation Review` in `workflow.allowed_transitions`, `workflow.human_review_states`, and implementation profile `target_states`.
- `lib/symphony_elixir/config/schema.ex` enforces `@linear_state_name_max_length 25`.
- `test/symphony_elixir/workspace_and_config_test.exs` explicitly asserts that `Needs Implementation Review` is rejected.
- Local verification:
  - `mise exec -- mix run -e 'case SymphonyElixir.Workflow.load("workflow.yml") do {:ok, wf} -> IO.inspect(SymphonyElixir.Config.Schema.parse(wf.config), limit: :infinity); other -> IO.inspect(other) end'`
  - Result: `{:error, {:invalid_workflow_config, "... Needs Implementation Review ... exceeds Linear state name limit of 25 characters ..."}}`

Impact:

Operators following the repo-local split package can import a workflow that later fails current runtime validation. This is the most direct code/document mismatch because the repository's own example package does not satisfy the repository's own schema contract.

Plan:

- Replace the repo-local implementation review state with `In Review` across `workflow.yml` and `profiles.yml`.
- Update root and Elixir README state-flow examples to use `In Review`.
- Keep `Needs Refinement Review` because it is within the 25-character limit.
- Add or keep regression coverage that parses the bundled split package through `Config.Schema.parse/1`, not only `Workflow.load/1`.

Acceptance criteria:

- `SymphonyElixir.Workflow.load("workflow.yml")` followed by `Config.Schema.parse/1` returns `{:ok, settings}`.
- README, user guide, workflow package, profile prompt, and schema defaults all describe the same default state flow.

### P0: Root architecture still says Codex gets `linear_graphql`

Evidence:

- `ARCHITECTURE.md` has a Mermaid edge `codex -->|linear_graphql tool| linear`.
- `ARCHITECTURE.md` section 6.8 says this layer exposes a client-side `linear_graphql` dynamic tool.
- Current code in `lib/symphony_elixir/codex/dynamic_tool.ex` exposes only `linear_task_read` and `linear_task_update`.
- `test/symphony_elixir/dynamic_tool_test.exs` explicitly refutes `linear_graphql` in tool specs.

Impact:

This is a security-model documentation bug. It tells implementers and operators that Codex may have raw Linear GraphQL access even though current design intentionally removed it.

Plan:

- Update `ARCHITECTURE.md` diagrams and section 6.8 to describe restricted dynamic tools.
- State that Linear GraphQL remains an internal backend/client implementation detail.
- Add a short note linking this to the restricted `linear_task_read` / `linear_task_update` contract.

Acceptance criteria:

- No operator-facing architecture doc says Codex is given `linear_graphql`.
- Architecture diagrams show Codex calling restricted task tools through Symphony.

### P1: `docs/codex_linear_interaction.zh-CN.md` mixes completed migration history with current state

Evidence:

- The document's "当前状态" says current code still has `linear_graphql`.
- Its migration path says to remove `linear_graphql` and add `linear_task_read` / `linear_task_update`.
- Current code and tests show that migration has already happened.

Impact:

The doc is useful as design history, but its current wording is stale and can send future implementers back toward already-completed work.

Plan:

- Convert the stale "当前状态" section into "历史背景".
- Add a "当前实现" section that names `linear_task_read` and `linear_task_update` as the live tool contract.
- Mark the raw GraphQL removal migration as completed, leaving any remaining gaps as follow-up items only if still unimplemented.

Acceptance criteria:

- The document clearly separates historical design rationale from current runtime behavior.
- It no longer claims that current Codex-visible tools include raw GraphQL.

### P1: Approval-policy docs disagree with current schema and long-term direction

Evidence:

- `elixir/README.md` says `codex.approval_policy` defaults to a structured `reject` map and that object-form `reject` is supported.
- `docs/user_guide.zh-CN.md` and `docs/workflow_page_design.zh-CN.md` say the public contract is the string enum `untrusted`, `on-failure`, `on-request`, `granular`, `never`, defaulting to `never`.
- `lib/symphony_elixir/config/schema.ex` uses default `"never"` and normalizes maps containing `"reject"` to `"never"`.
- `test/symphony_elixir/app_server_test.exs` covers Codex rejecting unknown `reject` variants.

Impact:

Operators may copy the old map form into new config and believe it is the preferred secure default. The implementation currently treats it as legacy compatibility, not the public configuration shape.

Plan:

- Update `elixir/README.md` to say the public default is `never`.
- Clarify that legacy `reject` maps are normalized for compatibility and should not be written into active workflow packages.
- Keep warning text about Codex app-server schema compatibility.

Acceptance criteria:

- All public docs describe string approval-policy values as the supported contract.
- No setup guide recommends object-form `reject` as a default.

### P1: State-flow terminology is split between `Needs Implementation Review` and `In Review`

Evidence:

- `elixir/README.md` and repo-local `workflow.yml` use `Needs Implementation Review`.
- `docs/user_guide.zh-CN.md`, `docs/codex_linear_interaction.zh-CN.md`, schema defaults, and most tests use `In Review`.
- `docs/long_term_direction.zh-CN.md` explicitly explains that `Needs Implementation Review` exceeds the Linear state-name length limit and recommends `In Review`.

Impact:

This fragmentation affects examples, workflow import, operator setup, agent prompts, tests, and Linear diagnostics. It is the same root problem as the invalid bundled package, but broad enough to require a coordinated doc/package sweep.

Plan:

- Choose `In Review` as the canonical implementation review state.
- Sweep `README.md`, `elixir/README.md`, `workflow.yml`, `profiles.yml`, and implementation workflow docs for canonical naming.
- Keep legacy-state rejection tests as negative coverage.

Acceptance criteria:

- Canonical docs and example packages use `In Review`.
- Negative tests still prove that too-long Linear state names produce actionable configuration errors.

### P1: `AGENTS.md` still describes file-backed runtime configuration

Evidence:

- `elixir/AGENTS.md` says "File-backed runtime config is loaded as a workflow package".
- The CLI, README, persistence docs, and tests now state that runtime source is SQLite active workflow version; split packages are import/export artifacts.

Impact:

This file guides future coding agents. Stale instructions increase the chance that future changes reintroduce file-backed startup assumptions or update the wrong artifacts as runtime authority.

Plan:

- Rewrite the convention as "SQLite active workflow version is runtime authority".
- Keep `workflow.yml` and `profiles.yml` as import/export package artifacts and examples.
- Update the docs policy to say package artifacts should be updated when the import/export contract changes, not whenever runtime config changes.

Acceptance criteria:

- Agent-facing repository instructions match DB-only runtime behavior.
- No AGENTS instruction tells agents that local package files are runtime source.

### P1: Exec-plan index is stale

Evidence:

- `docs/exec-plans/README.md` lists completed plans through 073, skips 074-086, then resumes at 087.
- The completed directory contains 074-086.
- The README active list has only 103.
- There is a numbering gap at 043 in the completed directory.

Impact:

The exec-plan archive is the project's main implementation history. A stale index makes it harder to understand what has already been built and what remains active.

Plan:

- Regenerate or manually update the completed-plan index through the current highest completed plan.
- Decide whether 043 is intentionally missing; if yes, add an explicit "reserved/missing" note so it is not mistaken for a lost plan.
- Add a lightweight check that compares `docs/exec-plans/README.md` against files in `completed/` and `active/`.

Acceptance criteria:

- The index includes 074-086 and any later completed plans.
- The 043 gap is either filled or documented.
- A local check fails when the index drifts from the filesystem.

### P2: `Workflow.load/1` can parse an invalid package that later fails runtime schema validation

Evidence:

- `Workflow.load("workflow.yml")` returned `{:ok, workflow}` for the invalid current package.
- `Config.Schema.parse(workflow.config)` then rejected it.

Impact:

Import and diagnostic flows can show a package as syntactically valid before later runtime validation rejects it. That split is intentional in some draft-save paths, but it needs clearer boundaries and stronger package-level validation in tests/docs.

Plan:

- Keep `Workflow.load/1` as YAML/package parsing only if that boundary is intentional.
- Add explicit naming or docs: "load" means parse, not runtime-valid.
- Add a helper or test path for "parse and validate bundled package".

Acceptance criteria:

- Developers can easily run one check that verifies `workflow.yml` + `profiles.yml` are runtime-valid.
- Import UI messaging distinguishes YAML parse success from runtime configuration validity.

### P2: Large modules indicate accumulated coupling

Evidence:

- `lib/symphony_elixir/orchestrator.ex`: 2,652 lines.
- `lib/symphony_elixir_web/live/admin_live.ex`: 2,200 lines.
- `lib/symphony_elixir/codex/app_server.ex`: 1,373 lines.
- `lib/symphony_elixir/workspace.ex`: 1,294 lines.
- Several test files exceed 1,600 lines.

Impact:

The code is functional, but change risk is concentrated in very large modules. This makes reviews slower, increases merge conflict probability, and encourages tests that validate broad behavior through monolithic fixtures.

Plan:

- Split `AdminLive` by section/form/import/history responsibilities.
- Extract orchestrator submodules around dispatch policy, retry/reconciliation, worker-mode task creation, and session-history presentation.
- Extract Codex app-server protocol framing, launch policy, event humanization, and dynamic-tool dispatch boundaries.
- Extract workspace source-strategy operations from workspace lifecycle orchestration.
- Keep behavior stable and move tests alongside each extracted boundary.

Acceptance criteria:

- New modules have focused ownership and smaller tests.
- High-risk extracts have compatibility tests proving unchanged public behavior.

### P2: Coverage threshold is weakened by a broad ignored-module list

Evidence:

- `mix.exs` sets coverage threshold to 85.
- The `ignore_modules` list excludes many core modules, including `Orchestrator`, `AgentRunner`, `Codex.AppServer`, `Codex.DynamicTool`, `Workspace`, `Persistence`, multiple LiveViews/controllers, and Mix tasks.

Impact:

The reported coverage threshold can pass while large parts of the runtime control plane are excluded. This hides risk in the exact modules that supervise long-running agent work, workspace mutation, tool execution, and persistence.

Plan:

- Classify ignored modules by reason: hard external dependency, UI-only rendering, currently untested legacy, or intentionally covered by integration tests.
- Remove ignores for modules that already have deterministic tests.
- For remaining ignored modules, create targeted tests or document why they must stay ignored.
- Track coverage on extracted modules after the large-module refactor.

Acceptance criteria:

- The ignore list is smaller and justified.
- At least `Codex.DynamicTool`, pure config/presentation helpers, and extracted orchestration policies count toward coverage.

### P2: Local workflow command inherits all shell environment

Evidence:

- `workflow.yml` uses `codex --config shell_environment_policy.inherit=all ... app-server`.
- `lib/symphony_elixir/codex/app_server.ex` has a sensitive env denylist for launched processes.
- Docs emphasize that Codex should not receive Linear API keys or other sensitive credentials.

Impact:

The app-server launcher has scrub logic, but the package-level command still asks Codex to inherit all environment variables. This increases cognitive load and may become unsafe if command-level config and process env filtering diverge.

Plan:

- Decide whether `inherit=all` is still required for repo-local operation.
- Prefer an allowlist or documented minimal env contract for the repo-local workflow.
- Add a regression test that the final launched Codex environment does not include sensitive variables even when command config requests broad inheritance.

Acceptance criteria:

- The example workflow does not encourage broad env inheritance unless there is a documented reason.
- Sensitive env scrubbing remains covered at the process-launch boundary.

### P3: Docs still contain phase-oriented roadmap labels that are now stale

Evidence:

- `docs/long_term_direction.zh-CN.md` labels DB-only runtime as "阶段未到" even though CLI and persistence docs say database workflow source is current behavior.

Impact:

The long-term direction document is valuable, but stale phase labels make it hard to tell which items are still aspirational.

Plan:

- Add a dated "current status" block near the top.
- Reclassify completed, active, and future roadmap items.
- Link completed items to exec plans where possible.

Acceptance criteria:

- Readers can distinguish current behavior from future direction without reading code.

## Scope

- Update stale docs and package artifacts listed above.
- Add validation/tests/checks that prevent these fragments from drifting again.
- Keep behavior changes narrow; most fixes should be documentation, example-package, and test/check updates.

## Out of Scope

- Reworking the full product architecture.
- Changing Linear workflow semantics beyond canonicalizing the default review state.
- Replacing SQLite persistence or Phoenix LiveView.
- Implementing the large-module refactor in one PR; that should be split after this consistency cleanup.

## Acceptance Criteria

- The bundled split package parses and validates under current schema.
- Public docs agree on runtime source, Linear tool boundary, approval-policy shape, and default state flow.
- Exec-plan index matches active/completed plan files or has an automated drift check.
- Agent-facing instructions no longer conflict with DB-only runtime behavior.
- At least one check or test prevents reintroducing the invalid bundled workflow package.

## Test Cases

- `SymphonyElixir.Workflow.load("workflow.yml")` followed by `SymphonyElixir.Config.Schema.parse/1` succeeds.
- A regression test confirms `DynamicTool.tool_specs/0` only exposes `linear_task_read` and `linear_task_update`.
- A regression test confirms docs/package examples do not include `Needs Implementation Review` as a canonical state.
- A regression test or Mix task confirms `docs/exec-plans/README.md` is synchronized with `docs/exec-plans/active` and `completed`.
- Existing negative tests still reject too-long Linear state names.
- Existing approval-policy tests still normalize legacy `reject` maps to `never` and report clear Codex schema errors.

## Implementation Notes

- Do the consistency cleanup before any code extraction. The invalid package and stale security docs are higher risk than module size.
- Treat `Workflow.load/1` as a parser boundary unless the team decides to make it validate runtime config too.
- Prefer small, mechanical documentation updates in one PR, then separate technical-debt refactors into follow-up PRs.
- If updating plan indexes manually, avoid marking this audit plan completed until the actual consistency fixes land.

## Verification

Commands already run during audit:

- `git status --short --branch`
- `rg --files`
- `find . -maxdepth 3 -type f ...`
- `mise exec -- mix run -e 'IO.inspect(SymphonyElixir.Workflow.load("workflow.yml"), limit: :infinity)'`
- `mise exec -- mix run -e 'case SymphonyElixir.Workflow.load("workflow.yml") do {:ok, wf} -> IO.inspect(SymphonyElixir.Config.Schema.parse(wf.config), limit: :infinity); other -> IO.inspect(other) end'`
- `rg -n "Needs Implementation Review|In Review|reject|linear_graphql|file-backed|workflow\\.yml"`
- `wc -l` for large runtime/test modules

Verification for the future implementation:

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

Delivered as an audit cleanup plus guardrails rather than only a written plan. The repo-local workflow package now validates with the runtime schema, current docs describe DB-only runtime authority and restricted Linear task tools, and an index drift test protects the exec-plan README. Historical completed exec plans were intentionally not rewritten.

## Dependencies

- Completed plan 033 for restricted Linear task tools.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 086 for env-only Linear token handling.
- Completed plan 096 for workspace source root layout.
- Completed plan 102 for removing hidden Codex `reject` approval-policy defaults.

## Handoff Notes

Prioritize the P0 and P1 items first. The repository currently contains enough mixed-era documentation that future changes can easily target the wrong runtime contract. The safest first PR should make docs, package examples, and tests agree on the existing behavior before refactoring large modules or tightening coverage.
