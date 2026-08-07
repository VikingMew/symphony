# Documentation Index

This index classifies every Markdown document directly under the current `elixir/docs/`
layout. Plan 226 will promote that directory to repository-root `docs/`; entries marked
**pending 227** also change filename or converge physically during the documentation sweep.
Exec plans are governed separately by `exec-plans/README.md` and are excluded here.

| Layer | Current document | Purpose / target note |
| --- | --- | --- |
| L0 | [`README.md`](README.md) | Navigation and layer registry. |
| L0 | [`decisions.md`](decisions.md) | Accepted architectural and process decisions. |
| L0 | [`documentation-system-design.md`](documentation-system-design.md) | Documentation governance and migration design. |
| L0 | [`documentation_alignment.md`](documentation_alignment.md) | Consistency ownership matrix; **pending 227** rename to `documentation-alignment.md`. |
| L1 | [`long_term_direction.zh-CN.md`](long_term_direction.zh-CN.md) | System direction and architectural roadmap. |
| L3 | [`codex_linear_implementation_workflow.zh-CN.md`](codex_linear_implementation_workflow.zh-CN.md) | Implementation workflow design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`codex_linear_interaction.zh-CN.md`](codex_linear_interaction.zh-CN.md) | Codex/Linear interaction design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`codex_linear_task_refinement_workflow.zh-CN.md`](codex_linear_task_refinement_workflow.zh-CN.md) | Refinement workflow design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`dashboard_color_system_design.zh-CN.md`](dashboard_color_system_design.zh-CN.md) | Dashboard color-system design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`hot_update.zh-CN.md`](hot_update.zh-CN.md) | Hot-update capability design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`worker_panel_decoupling_design.zh-CN.md`](worker_panel_decoupling_design.zh-CN.md) | Panel/worker boundary design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`workflow_page_design.zh-CN.md`](workflow_page_design.zh-CN.md) | Workflow page design; **pending 227** `<concern>-design.md` normalization. |
| L3 | [`workspace_source_layout.zh-CN.md`](workspace_source_layout.zh-CN.md) | Workspace source-layout design; **pending 227** `<concern>-design.md` normalization. |
| L4 | [`logging.md`](logging.md) | Logging contract. |
| L4 | [`persistence_and_auth.md`](persistence_and_auth.md) | Persistence and authentication reference. |
| L4 | [`test_database_isolation.md`](test_database_isolation.md) | Test database-isolation contract. |
| L4 | [`token_accounting.md`](token_accounting.md) | Token-accounting reference. |
| L5 | [`deployment.md`](deployment.md) | Reverse-proxy and Kubernetes deployment guide. |
| L5 | [`user_guide.zh-CN.md`](user_guide.zh-CN.md) | Operator guide; **pending 227** rename to `user-guide.zh-CN.md`. |

L2 is intentionally empty in the current layout. Plan 227 creates `design.md`, merges the
code-structure material into it, and adds the feature-design index.
