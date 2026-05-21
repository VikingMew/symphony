# 111 Follow-up Audit After Helper Extractions

Status: Completed

## Context

This audit re-read the current repository after the recent helper extractions and completed-plan moves. The goal was to record remaining redundant code, technical debt, documentation drift, and exec-plan numbering/index risks without changing production code.

The workspace already contains broad uncommitted changes, including new shared modules such as `SymphonyElixir.Shell`, `SymphonyElixir.Redaction`, `SymphonyElixir.StateName`, `SymphonyElixir.Payload`, `SymphonyElixir.RunHistory`, and `SymphonyElixir.RunLifecycle`. This plan treats those changes as existing work and only documents follow-up issues.

## Findings

### 1. Helper extraction is incomplete across several old call sites

Shared modules now exist, but multiple modules still keep private implementations or local wrappers for the same behavior:

- `shell_escape/1` still appears in `config/schema.ex`, `codex/app_server.ex`, `ssh.ex`, `runtime_proxy.ex`, and `workspace.ex` even though `SymphonyElixir.Shell.escape/1` exists.
- `map_value/3`, `map_path/3`, or equivalent atom/string key lookup helpers remain in `orchestrator.ex` and `status_dashboard.ex`, while `SymphonyElixir.Payload.get_any/3` and `get_path/3` now exist.
- Manual `Map.get(map, "key") || Map.get(map, :key)` access remains in multiple code paths, including `http_server.ex`, `persistence.ex`, `codex/app_server.ex`, `dynamic_tool.ex`, `status_dashboard.ex`, and `orchestrator.ex`.
- `blank?/1` and issue-state normalization wrappers still exist locally in multiple modules even though `SymphonyElixir.StateName.normalize/1` and `blank_string?/1` now exist.
- Redaction is partly centralized, but `sanitize_*` functions still exist in `git.ex`, `workspace.ex`, `codex/app_server.ex`, `linear/client.ex`, `linear/diagnostics.ex`, and `status_dashboard.ex`.

Plan:

1. Build a call-site inventory grouped by helper category: shell escaping, redaction, state normalization, blank checks, and mixed atom/string payload access.
2. Replace local private helpers where the shared helper is a direct semantic match.
3. Keep local wrappers only when they add domain-specific behavior, and name that behavior explicitly.
4. Add focused tests around the shared helper contracts before removing the last local copies.

Acceptance criteria:

- No private `shell_escape/1` remains outside `SymphonyElixir.Shell` unless a documented exception exists.
- Mixed atom/string payload access uses `SymphonyElixir.Payload` in orchestration, status, persistence, and web-facing paths.
- Redaction call sites use `SymphonyElixir.Redaction` for shared credential, ANSI/control, URI userinfo, and bounded-output behavior.
- Local normalization wrappers either disappear or become thin, named domain adapters.

### 2. Completed plans 105 and 109 now read as partially completed, not fully complete

`completed/105-large-module-boundary-refactor.md` says broad large-module decomposition remains future work, but the plan is marked completed. Current large modules still include `admin_live.ex`, `orchestrator.ex`, `codex/app_server.ex`, and `workspace.ex`.

`completed/109-redundant-code-and-plan-numbering-audit.md` records helper extraction work as completed, but this follow-up audit still finds private helper copies and manual mixed-key access patterns.

Plan:

1. Treat completed plans 105 and 109 as completed first slices, not proof that the original debt class is closed.
2. Create follow-up execution plans for any remaining large-module decomposition and helper-migration work before making further code changes.
3. When a plan is completed with deliberate scope reduction, move unfinished acceptance criteria into an explicit follow-up plan instead of leaving them only in completion deviations.

Acceptance criteria:

- Future completed plans do not leave high-priority acceptance criteria unresolved without a linked follow-up.
- Large-module debt and helper-migration debt each have a current active or proposed plan that reflects the remaining work, not only the first completed slice.

### 3. Exec-plan numbering and directory convention were inconsistent again

The original active/completed numbering scan reported:

```text
missing 43
highest 109
```

Earlier audit output treated root-level numbered plans as possible, but the current convention requires every exec plan to live under either `docs/exec-plans/active/` or `docs/exec-plans/completed/`. During completion, plan 110 was moved from the root into `completed/`, the README was updated, and the index test now guards against root-level numbered exec plans. This means:

- Root-level numbered plans should be treated as invalid, not just unindexed.
- `ExecPlanIndexTest` should fail if any `docs/exec-plans/[0-9][0-9][0-9]-*.md` file appears outside `active/` or `completed/`.
- The README should show active plans from `active/` and completed plans from `completed/`, with no root-level numbered links.
- The historical missing number 043 is still not documented in the index as an intentional gap.

Plan:

1. Decide whether proposed plans belong in `docs/exec-plans/`, `docs/exec-plans/active/`, or a separate `proposed/` directory.
2. Update the index test to validate every numbered Markdown plan under `docs/exec-plans/`, not only active/completed links.
3. Add an explicit note for missing number 043 if the gap is intentional.
4. Keep plan 111 in `active/` until it is completed, then move it to `completed/`.

Acceptance criteria:

- One command reports the same highest plan number users see in the README.
- Root-level numbered plans cannot exist without failing the index test.
- Intentional numbering gaps are documented.

### 4. Long-term direction docs are stale about `backend_action`

`docs/long_term_direction.zh-CN.md` still describes `backend_action` as mostly a future configuration contract and says the orchestrator only automatically executes `codex_agent`. Current code and config have moved further:

- `SymphonyElixir.MergeExecutor` exists.
- `AgentRunner` dispatches merge profiles to backend merge execution.
- `Orchestrator.executable_state?/1` treats both `codex_agent` and `backend_action` as executable.
- `profiles.yml` describes the default merge path through the backend merge executor.

Plan:

1. Update the long-term direction document to distinguish already implemented backend merge execution from future non-merge backend actions.
2. Add a short architecture note that defines when `backend_action` is executable, which executor owns it, and where merge-specific behavior stops.
3. Keep future roadmap language only for capabilities that are still actually missing.

Acceptance criteria:

- Documentation no longer says only `codex_agent` is automatically executed.
- `backend_action` docs match `MergeExecutor`, `AgentRunner`, `Orchestrator`, and `profiles.yml`.

### 5. `turn_sandbox_policy` UI drift was handled in plan 110

The code and docs support `codex.turn_sandbox_policy`, and `workflow.yml` contains it. Plan 110 now exposes turn sandbox policy in the workflow form and admin UI separately from thread sandbox policy.

This audit does not duplicate implementation scope. It records that the issue was found here and completed by plan 110.

Plan:

1. Keep all implementation details in plan 110.
2. Ensure plan 110 also covers persistence and loaded-form round trips for `codex_turn_sandbox_policy`, not only the visible UI control.

Acceptance criteria:

- `WorkflowForm.from_loaded/1`, `WorkflowForm.to_config/1`, and `AdminLive` controls preserve and expose `turn_sandbox_policy`.

### 6. Coverage-ignore governance improved but remains a residual debt area

The coverage ignore list now has more rationale and some extracted helper modules are covered. Large behavioral or presentation-heavy modules still remain ignored, including orchestration, workspace, dynamic tool, and dashboard paths.

Plan:

1. Keep the rationale comments, but convert each broad ignored module into one of three categories: protocol boundary, presentation shell, or missing-test debt.
2. For missing-test debt, create small follow-up plans instead of letting the ignore list act as a permanent waiver.
3. Add a periodic check that fails when new ignored modules are added without a reason and owner.

Acceptance criteria:

- Every coverage ignore entry has a reason and a removal condition.
- Newly extracted pure helper modules are not added to the ignore list by default.

### 7. Test YAML generation still has serializer debt

Plan 109 called out repeated hand-rolled YAML fixture generation. Current tests still include bespoke YAML string generation and normalization patterns. That may be acceptable as a temporary fixture strategy, but it should not keep spreading.

Plan:

1. Introduce a small test-only workflow fixture builder or use a structured YAML encoder if the dependency policy allows it.
2. Replace repeated heredoc/interpolation YAML fixtures in tests that exercise the same workflow schema.
3. Keep one or two explicit fixture files only where exact formatting matters.

Acceptance criteria:

- Workflow-schema tests share one fixture construction path.
- Adding a new workflow field requires changing one test fixture builder, not many interpolated YAML blocks.

## Verification Performed

- Re-read current git status to account for existing user/generated changes.
- Re-scanned repository files with `rg --files`.
- Re-scanned helper duplicates using `rg` for `shell_escape`, `map_value`, `map_path`, `Map.get(... "key")`, `blank?`, `normalize_issue_state`, and `sanitize_`.
- Checked exec-plan numbering across `docs/exec-plans/active` and `docs/exec-plans/completed`; result before completion: missing `043`, highest `109`.
- Confirmed root-level `docs/exec-plans/110-codex-turn-sandbox-policy-settings-ui.md` existed outside active/completed, then moved it to `completed/` as part of plan 110 completion.
- Updated the exec-plan index test through the earlier completed-plan work so root-level numbered plan drift is detected.
- Completed this audit as a documentation-only plan and moved it to `completed/`.

## Completion Deviations

- The original audit was written as a proposed follow-up, but the user requested all active exec plans be completed. This plan was completed as an audit/documentation artifact plus low-risk consistency cleanup, not as a broad production-code refactor.
- Direct `shell_escape/1`, `map_value/3`, `map_path/3`, and obvious mixed atom/string payload access duplicates were removed or moved behind shared helpers during completion.
- The `backend_action` long-term documentation drift was corrected so docs match the current backend merge executor behavior.
- Exec-plan index governance was tightened and the intentional `043` numbering gap was documented.
- Remaining helper-migration debt is transferred to [112 Helper Migration Completion](../active/112-helper-migration-completion.md).
- Remaining large-module decomposition debt is transferred to [113 Large Module Boundary Follow-up](../active/113-large-module-boundary-follow-up.md).
- Remaining coverage-ignore governance debt is transferred to [114 Coverage Ignore Exit Governance](../active/114-coverage-ignore-exit-governance.md).
- Remaining test YAML fixture debt is transferred to [115 Test YAML Fixture Builder](../active/115-test-yaml-fixture-builder.md).

## Non-goals

- Do not edit production code as part of this audit.
- Do not implement the transferred helper-migration, large-module, coverage-ignore, or YAML fixture refactors as part of this audit once they have their own active execplans.
