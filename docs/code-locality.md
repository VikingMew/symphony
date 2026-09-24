---
title: Code Locality Contract and Audit
genre: reference
domain: [backend, quality, testing]
status: current
language: en
updated: 2026-09-24
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
| Temporary clause debt | Exact path, identifier, measured lines, split cut, owner, and due date; due dates must be current and at most 30 days out; the file must contain a nearby `Locality split index:` marker. |
| Nesting | At most 2 across `if`, `unless`, `case`, `cond`, `fn`, `for`, and `with`, matching the pinned Credo check. |
| Remote calls | At most 2 consecutive actual calls on one receiver path. Zero-argument field access does not count. `value |> A.call() |> B.call() |> C.call()` is allowed because its boundaries are explicit. |
| Generated artifacts | A canonical manifest entry plus `Generated from: <source-or-command>` and `DO NOT EDIT` within the first five non-empty lines. |
| Determinism | Paths and violations are sorted; the same tree and date produce identical output and status. |

`config/locality.exs` is the single machine-readable inventory. `code_extensions` and
`code_basenames` define code; `data_paths` holds only tracked standard data/binary artifacts;
`generated` holds generated artifacts; `clause_exceptions` is temporary clause debt. There is no
handwritten file-size allowlist. Current data entries are the three `.github/media` binaries,
`docs/negative-assertion-inventory.tsv`, and `mix.lock`. The generated inventory is empty: all
tracked source and static assets are handwritten. The stale snapshot `.gitattributes` rule and tracked `.DS_Store` metadata were deleted because
neither is a maintained source or asset contract.

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
| L-02 | Partially compliant. No clause gate or dated register existed. | Add token-metadata AST measurement and the temporary register below. | Compliant. Every clause is at most 60 lines or has all six required fields and a nearby index marker. |
| L-03 | Compliant baseline: `mix credo --strict --format json` reported zero issues with Credo 1.7.16 default depth 2. | Pin `max_nesting: 2`, add an AST-focused test, and extract four newly surfaced nested control paths. | Compliant. Credo and `mix locality.check` report no nesting issue and no nesting suppression was added. |
| L-04 | Not compliant. No reproducible conceptual-locality sample existed. | Define the sorted/even sample and review all 44 rows below. | Compliant. 45 of 444 code files (10.1%) pass the no-navigation concept review; split section samples were re-reviewed after extraction. |
| L-05 | Partially compliant. No AST gate or explicit pipeline ruling existed. | Check receiver-call AST, distinguish field access, document pipelines, and inspect module-boundary matches. | Compliant. The final AST scan has zero implicit three-call chain; focused tests cover a failing chain and allowed pipeline. |
| L-06 | Partially compliant. Policy literals had no single disposition record. | Review the literal inventory by category and retain runtime policy in `SymphonyElixir.Config` or named attributes. | Compliant. The classification below has no unexplained literal or new runtime config source. |
| L-07 | Not compliant. The generated/data inventory was absent and `.gitattributes` named a missing snapshot directory. | Add the canonical manifest/header check, classify data, and delete stale generated metadata/rules. | Compliant. Generated inventory is empty, all data entries exist, stale generated metadata/rules are gone, and focused tests cover headers, data, and stale entries. |
| L-08 | Not compliant because oversized files remained and long clauses had no nearby index. | Complete L-01 and add the index marker to every registered clause file. | Compliant. No long handwritten file remains; every temporary L-02 entry is indexed below and beside the code. |

Final totals: **compliant 8; non-compliant 0; not applicable 0; total 8**.

## L-04 deterministic sample

Sort the canonical 444-file code set. Let `n = 444`, `s = max(20, ceil(n / 10)) = 45`, and select
zero-based index `floor(i * n / s)` for every `i` from 0 through 44. Each row answers whether one
concept can be understood in the file without navigating elsewhere.

| File | Verdict and rationale |
| --- | --- |
| `.codex/skills/land/land_watch.py` | Pass — one repository automation command boundary. |
| `.github/workflows/pr-description-lint.yml` | Pass — one CI workflow and its repository check sequence. |
| `config/locality.exs` | Pass — one canonical locality manifest and debt register. |
| `lib/mix/tasks/symphony.build.ex` | Pass — one named Mix command boundary. |
| `lib/symphony_elixir/blocking_decision.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/codex/linear_tool_audit/panel_recorder.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/codex/refinement_description_measurement.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/config/runtime_resolver.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/event_presenter.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/linear/health.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/migration_check.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/orchestrator/sections/control.ex` | Pass — one responsibility-named compile-time section of its owning runtime module. |
| `lib/symphony_elixir/persistence/app_setting.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/persistence/workflow_record.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/pr_review/store.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/runtime_proxy.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/worker/application.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/worker/heartbeat_history.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/workflow_settings_package.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir/workspace_disk_guard.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir_web/controllers/static_asset_controller.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir_web/live/admin_live/observability_components.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir_web/live/admin_live/workflow_state.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `lib/symphony_elixir_web/router.ex` | Pass — one module or tightly coupled module family with a responsibility named by the path. |
| `priv/repo/migrations/20260519000000_remove_project_worktree_roots.exs` | Pass — one monotonic schema or data transition. |
| `priv/repo/migrations/20260906000000_allow_legacy_worker_session_writes.exs` | Pass — one monotonic schema or data transition. |
| `scripts/manual_handoff.sh` | Pass — one repository check or operator command entrypoint. |
| `test/support/live_e2e_docker/Dockerfile` | Pass — one live-E2E worker build fixture. |
| `test/support/locality_sections/core_2.exs` | Pass — one coherent scenario group composed by its small test wrapper. |
| `test/symphony_elixir/analytics_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/codex/app_server_dynamic_tool_policy_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/codex/message_usage_formatter_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/config/codex_command_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/coverage_ignore_governance_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/execution_worker_deployment_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/linear_health_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/mixed_key_access_governance_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/orchestrator/session_history_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/payload_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/profile_prompt_summary_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/ssh_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/worker/http_integration_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/workflow_form_disk_guard_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir/workspace/source_preparation_test.exs` | Pass — focused tests for the contract named by the path. |
| `test/symphony_elixir_web/control_api_controller_test.exs` | Pass — focused tests for the contract named by the path. |

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

The manifest is authoritative and the table below is its review projection. The due date is within
30 days of this audit. `mix locality.check` rejects changed measurements, missing fields, missing
nearby markers, expiry, and dates beyond the allowed window.

| Path | Clause identifier | Lines | Split cut | Owner | Due |
| --- | --- | ---: | --- | --- | --- |
| `lib/symphony_elixir/analytics.ex` | `quality/6@83` | 61 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/codex/app_server.ex` | `handle_incoming/6@615` | 62 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/codex/app_server.ex` | `handle_turn_method/8@740` | 74 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/codex/app_server.ex` | `run_turn/4@87` | 109 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/codex/dynamic_tool/sections/request_execution.ex` | `__using__/1@6` | 544 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/codex/dynamic_tool/sections/updates.ex` | `__using__/1@6` | 639 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/config/schema/sections/defaults.ex` | `__using__/1@6` | 320 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/config/schema/sections/defaults.ex` | `default_profiles/0@85` | 79 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/config/schema/sections/parsing.ex` | `__using__/1@6` | 304 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/config/schema/sections/types.ex` | `__using__/1@6` | 599 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/completion.ex` | `__using__/1@6` | 330 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/control.ex` | `__using__/1@6` | 931 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/control.ex` | `handle_call/3@212` | 99 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/dispatch.ex` | `__using__/1@6` | 725 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/dispatch.ex` | `dispatch_issue_agent/7@122` | 80 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/lifecycle.ex` | `__using__/1@6` | 785 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/persistence.ex` | `__using__/1@6` | 388 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/reconciliation.ex` | `__using__/1@6` | 800 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/orchestrator/sections/runtime_status.ex` | `__using__/1@6` | 906 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/worker/assignment_manager/sections/api.ex` | `__using__/1@6` | 681 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/worker/assignment_manager/sections/api.ex` | `handle_call/3@349` | 66 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/worker/assignment_manager/sections/assignment.ex` | `__using__/1@6` | 728 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/worker/executor.ex` | `execute/3@20` | 64 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/worker/executor.ex` | `run_codex/5@85` | 68 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/workspace/sections/hooks.ex` | `__using__/1@6` | 745 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/workspace/sections/hooks.ex` | `run_hook/7@129` | 66 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/workspace/sections/lifecycle.ex` | `__using__/1@6` | 726 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir/workspace/sections/lifecycle.ex` | `prepare_worktree_source/4@309` | 101 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/events.ex` | `render/1@11` | 111 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/run_detail.ex` | `render/1@13` | 107 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/settings/agents.ex` | `render/1@14` | 164 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/settings/import.ex` | `render/1@15` | 80 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/settings/projects.ex` | `render/1@14` | 118 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/admin_live/settings/runtime.ex` | `render/1@14` | 82 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/analytics_live.ex` | `render/1@22` | 150 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/dashboard_live.ex` | `render/1@118` | 431 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/linear_diagnostics_live.ex` | `render/1@65` | 259 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `lib/symphony_elixir_web/live/workers_live.ex` | `render/1@19` | 92 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `mix.exs` | `coverage_ignore_groups/0@53` | 136 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `priv/repo/migrations/20260501000000_create_symphony_persistence.exs` | `change/0@5` | 132 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `priv/repo/migrations/20260501001000_create_worker_control_plane.exs` | `change/0@5` | 72 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `test/support/fake_persistence_sections/fake_persistence_1.exs` | `__using__/1@6` | 585 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/fake_persistence_sections/fake_persistence_2.exs` | `__using__/1@6` | 644 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/agent_runner_1.exs` | `__using__/1@6` | 560 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/agent_runner_2.exs` | `__using__/1@6` | 413 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/assignment_manager_1.exs` | `__using__/1@6` | 815 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/assignment_manager_2.exs` | `__using__/1@6` | 850 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/assignment_manager_3.exs` | `__using__/1@6` | 575 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/core_1.exs` | `__using__/1@6` | 848 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/core_2.exs` | `__using__/1@6` | 767 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/extensions_1.exs` | `__using__/1@6` | 784 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/extensions_2.exs` | `__using__/1@6` | 641 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/orchestrator_status_1.exs` | `__using__/1@6` | 808 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/orchestrator_status_2.exs` | `__using__/1@6` | 758 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/orchestrator_status_3.exs` | `__using__/1@6` | 596 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/locality_sections/orchestrator_status_4.exs` | `__using__/1@6` | 367 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/test_support.exs` | `__using__/1@122` | 94 | Replace the compile-time section with cohesive helper modules after behavior-locking extraction. | Symphony maintainers | 2026-10-23 |
| `test/support/test_support.exs` | `workflow_content/1@322` | 152 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
| `test/symphony_elixir/live_e2e_test.exs` | `run_live_issue_flow!/1@410` | 82 | Extract named helpers or view components at the existing control-flow boundaries. | Symphony maintainers | 2026-10-23 |
