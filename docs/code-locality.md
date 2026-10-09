---
title: Code Locality Contract and Audit
genre: reference
domain: [backend, quality, testing]
status: current
language: en
updated: 2026-10-08
owner: SymphonyElixir.Locality
---

# Code Locality Contract and Audit

This L4 document owns the current locality thresholds, scan and exclusion contract, temporary
clause register, and L-01 through L-08 audit. Design rationale is in
[code-locality-design.md](code-locality-design.md).

## Machine contract

| Concern | Contract |
| --- | --- |
| Handwritten file size | At most 1,000 physical lines. |
| Elixir clause size | At most 60 physical lines from `def`, `defp`, `defmacro`, or `defmacrop` through its token-metadata end. |
| Temporary clause debt | Exact path, identifier, measured lines, split cut, and owner; entries are dateless and only decrease; the file must contain a nearby `Locality split index:` marker. |
| Nesting | At most 2 across `if`, `unless`, `case`, `cond`, `fn`, `for`, and `with`, matching the pinned Credo check. |
| Remote calls | At most 2 consecutive actual calls on one receiver path. Zero-argument field access does not count. `value |> A.call() |> B.call() |> C.call()` is allowed because its boundaries are explicit. |
| Generated artifacts | A canonical manifest entry plus `Generated from: <source-or-command>` and `DO NOT EDIT` within the first five non-empty lines. |
| Determinism | Paths and violations are sorted; the same tree produces identical output and status. Every run emits exactly one `locality_waterline` line with `exemptions_remaining`, `max_file_lines`, and `max_clause_lines`. |

`config/locality.exs` is the single machine-readable inventory. `code_extensions` and
`code_basenames` define code; `data_paths` holds only tracked standard data/binary artifacts;
`generated` holds generated artifacts; `clause_exceptions` is the dateless, only-decreasing baseline
for existing clause debt. There is no
handwritten file-size allowlist. Current data entries are the three `.github/media` binaries,
`docs/negative-assertion-inventory.tsv`, and `mix.lock`. The generated inventory is empty: all
tracked source and static assets are handwritten. The main-branch `.gitattributes` rule is retained
for future generated status-dashboard snapshots;
no tracked file currently matches it, so it does not add a generated manifest entry. The unrelated
tracked `.DS_Store` metadata was deleted.

## Reproduction

```bash
git ls-files -z -- '*.ex' '*.exs' '*.sh' '*.css' '*.js' '*.yml' '*.yaml' | xargs -0 wc -l | sort -nr
mix locality.check
mix credo --strict --format json
```

For determinism, run `mix locality.check` twice, capture stdout and exit status, and compare both.
The gate also runs through `scripts/check.sh` via `mix lint`.

## L-01 through L-08 audit

| Rule | Initial verdict and evidence | Remediation | Final verdict and evidence |
| --- | --- | --- | --- |
| L-01 | Not compliant. The baseline command found 12 handwritten files over 1,000 lines; `lib/symphony_elixir/orchestrator.ex` was 4,239 and `priv/static/dashboard.css` was 1,397. | Split runtime/test responsibilities and CSS; add the tracked-file gate with no handwritten grandfather entry. | Compliant. The baseline command and `mix locality.check` report no oversized handwritten file. |
| L-02 | Partially compliant. No clause gate or exact debt register existed. | Add token-metadata AST measurement and a 59-entry temporary register. | Compliant. Every clause is at most 60 lines or belongs to the current 56-entry dateless baseline with all five required fields and a nearby index marker; three starting entries were removed after their clauses fell below the limit. |
| L-03 | Compliant baseline: `mix credo --strict --format json` reported zero issues with Credo 1.7.16 default depth 2. | Pin `max_nesting: 2`, add an AST-focused test, and extract four newly surfaced nested control paths. | Compliant. Credo and `mix locality.check` report no nesting issue and no nesting suppression was added; responsibility fragments suppress only the `LongQuoteBlocks` advisory at their compile-time `quote` boundary. |
| L-04 | Not compliant. No reproducible conceptual-locality sample existed. | Define the sorted/even sample and review all 52 rows below. | Compliant. 52 of 515 code files (10.1%) pass the no-navigation concept review; split section samples were re-reviewed after the main merge. |
| L-05 | Partially compliant. No AST gate or explicit pipeline ruling existed. | Check receiver-call AST, distinguish field access, document pipelines, and inspect module-boundary matches. | Compliant. The final AST scan has zero implicit three-call chain; focused tests cover a failing chain and allowed pipeline. |
| L-06 | Partially compliant. Policy literals had no single disposition record. | Review the literal inventory by category and retain runtime policy in `SymphonyElixir.Config` or named attributes. | Compliant. The classification below has no unexplained literal or new runtime config source. |
| L-07 | Not compliant. The generated/data inventory was absent and `.gitattributes` named a snapshot directory with no current tracked files. | Add the canonical manifest/header check, classify data, retain main's future snapshot marker, and delete unrelated `.DS_Store` metadata. | Compliant. Generated inventory is empty, all data entries exist, the snapshot marker has no current tracked match, and focused tests cover headers, data, and stale entries. |
| L-08 | Not compliant because oversized files remained and long clauses had no nearby index. | Complete L-01 and add the index marker to every registered clause file. | Compliant. No long handwritten file remains; all 56 remaining temporary L-02 entries are indexed below and beside the code. |

Final totals: **compliant 8; non-compliant 0; not applicable 0; total 8**.

## L-04 deterministic sample

Sort the canonical 515-file code set. Let `n = 515`, `s = max(20, ceil(n / 10)) = 52`, and select
zero-based index `floor(i * n / s)` for every `i` from 0 through 51. Each row answers whether one
concept can be understood in the file without navigating elsewhere.

| File | Verdict and rationale |
| --- | --- |
| `.codex/skills/land/land_watch.py` | Pass — one repository automation command boundary. |
| `.github/workflows/publish-image.yml` | Pass — one CI workflow and its repository check sequence. |
| `config/agent_code_governance.yml` | Pass — one canonical governance and threshold inventory. |
| `lib/mix/tasks/agent_code_x.check.ex` | Pass — one named Mix command boundary. |
| `lib/mix/tasks/symphony/postgres_smoke_assertions.ex` | Pass — focused assertions for the PostgreSQL smoke boundary. |
| `lib/symphony_elixir/auth.ex` | Pass — one authentication boundary. |
| `lib/symphony_elixir/codex/app_server/sections/tail_3.ex` | Pass — one responsibility-named compile-time section of its owning runtime module. |
| `lib/symphony_elixir/codex/dynamic_tool/sections/dynamic_tool_updates.ex` | Pass — one responsibility-named compile-time section of its owning runtime module. |
| `lib/symphony_elixir/codex/protocol.ex` | Pass — one Codex protocol boundary. |
| `lib/symphony_elixir/config/codex_command.ex` | Pass — one configuration projection for Codex commands. |
| `lib/symphony_elixir/config/workflow_scopes.ex` | Pass — one workflow-scope configuration concern. |
| `lib/symphony_elixir/linear/diagnostics.ex` | Pass — one Linear diagnostics boundary. |
| `lib/symphony_elixir/locality.ex` | Pass — one repository-locality checker. |
| `lib/symphony_elixir/orchestrator/dispatch_policy.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/orchestrator/sections/runtime_status.ex` | Pass — one responsibility-named compile-time section of its owning runtime module. |
| `lib/symphony_elixir/persistence/run_record.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/pr_review.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/release/legacy_workflow_command.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/sqlite_importer.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/worker/claim_commit.ex` | Pass — one worker claim-commit boundary. |
| `lib/symphony_elixir/worker/heartbeat_history.ex` | Pass — one worker heartbeat-history concern. |
| `lib/symphony_elixir/workflow_form.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/workspace_cleanup_policy.ex` | Pass — one workspace-cleanup policy boundary. |
| `lib/symphony_elixir_web/controllers/observability_api_controller.ex` | Pass — one observability API boundary. |
| `lib/symphony_elixir_web/live/admin_live/events.ex` | Pass — one admin event-view concern. |
| `lib/symphony_elixir_web/live/admin_live/settings_shell.ex` | Pass — one settings-shell presentation concern. |
| `lib/symphony_elixir_web/rate_limit_status.ex` | Pass — one rate-limit status projection. |
| `priv/repo/migrations/20260517000000_add_project_source_strategy_fields.exs` | Pass — one monotonic schema or data transition. |
| `priv/repo/migrations/20260905000000_move_capacity_to_deployment.exs` | Pass — one monotonic schema or data transition. |
| `priv/static/dashboard/components.css` | Pass — one dashboard component-style boundary. |
| `scripts/prepare_navigation_git_history.sh` | Pass — one repository-check preparation command. |
| `test/mix/tasks/pr_body_check_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/support/live_e2e_docker/live_worker_entrypoint.sh` | Pass — one opt-in live-E2E worker entrypoint. |
| `test/support/locality_sections/extensions_1.exs` | Pass — one coherent scenario group composed by its small test wrapper. |
| `test/symphony_elixir/agent_code_check_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/application_startup_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/codex/dynamic_tool_policy_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/codex/refinement_quality_gate_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/config/schema_domain_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/default_test_boundary_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/github_pull_request_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/linear_workflow_state_validator_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/number_format_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/orchestrator/session_history_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/persistence/legacy_workflow_reconciliation_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/prompt_builder_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/shell_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/worker/assignment_manager_event_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/worker/paths_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/workflow_settings_package_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/workspace_and_config_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir_web/dashboard_presenter_test.exs` | Pass — focused tests for the contract named by the path. |

## L-06 literal classification

| Category | Search disposition |
| --- | --- |
| Runtime policy | Poll intervals, retry/backoff, concurrency, workspace roots, Codex policy, and workflow state policy are named attributes or read through `SymphonyElixir.Config`; no new environment/config read was added. |
| Protocol values | HTTP status codes, GraphQL operation strings, event/state names, and wire keys remain at their protocol boundary. |
| Structural values | `0`/`1`, collection offsets, boolean/default sentinels, arities, byte units, and pattern discriminants are not policy magic numbers. |
| Test and migration data | IDs, timestamps, ports, schema defaults, fixture counts, and assertion values remain local evidence. |
| Presentation | CSS dimensions/color tokens and display-only truncation limits remain in the presentation asset or named module attribute. |

Audit command: `rg -n '(#[0-9A-Fa-f]{3,8}|[2-9][0-9_]{2,}|"[A-Za-z][^"]+")' lib config priv scripts test`.
Every match was assigned to one row above; repeated or runtime-policy values already resolve to a
named attribute/config accessor. No unexplained policy literal remains.

## Temporary clause splits

The manifest is authoritative and the table below is its review projection. The baseline started at
59 and now contains 56 exact, dateless entries after three clauses fell below the limit. It has no date
or expiry semantics. `mix locality.check` rejects changed
paths, identifiers, measurements, missing fields, missing nearby markers, and every unregistered
overlong clause. The baseline may only decrease; when it reaches zero, a separate change removes the
mechanism.

| Path | Clause identifier | Lines | Split cut | Owner |
| --- | --- | ---: | --- | --- |
| `lib/symphony_elixir/analytics.ex` | `quality/6@83` | 61 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/codex/app_server.ex` | `handle_incoming/7@631` | 89 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/codex/app_server.ex` | `handle_turn_method/7@799` | 77 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/codex/app_server.ex` | `run_turn/4@87` | 102 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/codex/dynamic_tool/sections/request_execution.ex` | `__using__/1@6` | 575 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/codex/dynamic_tool/sections/dynamic_tool_updates.ex` | `__using__/1@6` | 662 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/config/schema/sections/defaults.ex` | `__using__/1@6` | 286 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/config/schema/sections/defaults.ex` | `default_profiles/0@86` | 79 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/config/schema/sections/parsing.ex` | `__using__/1@6` | 275 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/config/schema/sections/types.ex` | `__using__/1@6` | 553 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/completion.ex` | `__using__/1@6` | 339 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/control.ex` | `__using__/1@6` | 919 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/control.ex` | `handle_call/3@256` | 99 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/dispatch.ex` | `__using__/1@6` | 743 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/dispatch.ex` | `dispatch_issue_agent/8@196` | 86 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/lifecycle.ex` | `__using__/1@6` | 738 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/orchestrator_persistence.ex` | `__using__/1@6` | 402 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/reconciliation.ex` | `__using__/1@6` | 840 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/orchestrator/sections/runtime_status.ex` | `__using__/1@6` | 889 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/worker/assignment_manager/sections/api.ex` | `__using__/1@6` | 845 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/worker/assignment_manager/sections/assignment.ex` | `__using__/1@6` | 888 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/worker/executor.ex` | `run_codex/5@102` | 71 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir/workspace/sections/hooks.ex` | `__using__/1@6` | 573 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/workspace/sections/workspace_lifecycle.ex` | `__using__/1@6` | 564 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `lib/symphony_elixir/workspace/sections/workspace_lifecycle.ex` | `prepare_worktree_source/4@272` | 66 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/events.ex` | `render/1@11` | 111 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/run_detail.ex` | `render/1@13` | 120 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/settings/agents.ex` | `render/1@14` | 164 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/settings/import.ex` | `render/1@15` | 83 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/settings/projects.ex` | `render/1@14` | 147 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/admin_live/settings/runtime.ex` | `render/1@16` | 208 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/analytics_live.ex` | `render/1@22` | 150 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/dashboard_live.ex` | `render/1@118` | 431 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/linear_diagnostics_live.ex` | `render/1@65` | 283 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `lib/symphony_elixir_web/live/workers_live.ex` | `render/1@19` | 92 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `mix.exs` | `coverage_ignore_groups/0@53` | 136 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `priv/repo/migrations/20260501000000_create_symphony_persistence.exs` | `change/0@5` | 132 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `priv/repo/migrations/20260501001000_create_worker_control_plane.exs` | `change/0@5` | 72 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `test/support/fake_persistence_sections/fake_persistence_1.exs` | `__using__/1@6` | 621 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/fake_persistence_sections/fake_persistence_2.exs` | `__using__/1@6` | 660 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/agent_runner_1.exs` | `__using__/1@11` | 614 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/agent_runner_2.exs` | `__using__/1@11` | 471 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/assignment_manager_1.exs` | `__using__/1@16` | 722 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/assignment_manager_2.exs` | `__using__/1@18` | 768 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/assignment_manager_3.exs` | `__using__/1@20` | 509 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/core_1.exs` | `__using__/1@13` | 770 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/core_2.exs` | `__using__/1@15` | 693 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/extensions_1.exs` | `__using__/1@16` | 645 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/extensions_2.exs` | `__using__/1@13` | 551 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/orchestrator_status_1.exs` | `__using__/1@10` | 839 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/orchestrator_status_2.exs` | `__using__/1@11` | 672 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/orchestrator_status_3.exs` | `__using__/1@13` | 622 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/locality_sections/orchestrator_status_4.exs` | `__using__/1@10` | 349 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/test_support.exs` | `__using__/1@123` | 95 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers |
| `test/support/test_support.exs` | `workflow_content/1@330` | 152 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
| `test/symphony_elixir/live_e2e_test.exs` | `run_live_issue_flow!/1@410` | 82 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers |
