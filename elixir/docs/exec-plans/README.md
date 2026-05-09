# Symphony Exec Plans

Exec plans are implementation handoff documents. They define what to build, why it matters, what is in scope, how completion is verified, and what follow-up context future implementers need.

Plans should focus on product and engineering intent rather than full implementation code.

## Completed Plans

1. [001-simple-username-password-auth.md](completed/001-simple-username-password-auth.md)
2. [002-sqlite-configuration-foundation.md](completed/002-sqlite-configuration-foundation.md)
3. [003-load-workflow-from-database.md](completed/003-load-workflow-from-database.md)
4. [004-persist-runtime-state.md](completed/004-persist-runtime-state.md)
5. [005-manage-configuration-in-web-ui.md](completed/005-manage-configuration-in-web-ui.md)
6. [006-linear-key-multiple-project-trackers.md](completed/006-linear-key-multiple-project-trackers.md)
7. [007-improved-dashboard-pages.md](completed/007-improved-dashboard-pages.md)
8. [008-panel-worker-data-model.md](completed/008-panel-worker-data-model.md)
9. [009-worker-registration-handshake-api.md](completed/009-worker-registration-handshake-api.md)
10. [010-task-queue-lease-api.md](completed/010-task-queue-lease-api.md)
11. [011-worker-heartbeat-lease-expiry-cancellation.md](completed/011-worker-heartbeat-lease-expiry-cancellation.md)
12. [012-worker-result-event-reporting-api.md](completed/012-worker-result-event-reporting-api.md)
13. [013-scheduler-orchestrator-worker-integration.md](completed/013-scheduler-orchestrator-worker-integration.md)
14. [014-worker-dashboard-operator-controls.md](completed/014-worker-dashboard-operator-controls.md)
15. [015-worker-mode-cutover-compatibility.md](completed/015-worker-mode-cutover-compatibility.md)
16. [016-dashboard-color-system.md](completed/016-dashboard-color-system.md)
17. [017-port-mode-database-workflow-bootstrap.md](completed/017-port-mode-database-workflow-bootstrap.md)
18. [018-workflow-ui-create-from-empty-database.md](completed/018-workflow-ui-create-from-empty-database.md)
19. [019-startup-precedence-file-db-ui.md](completed/019-startup-precedence-file-db-ui.md)
20. [020-port-mode-without-workflow-test-docs.md](completed/020-port-mode-without-workflow-test-docs.md)
21. [021-dashboard-to-workflow-navigation.md](completed/021-dashboard-to-workflow-navigation.md)
22. [022-linear-integration-diagnostics-web-ui.md](completed/022-linear-integration-diagnostics-web-ui.md)
23. [023-workflow-runtime-source-consistency.md](completed/023-workflow-runtime-source-consistency.md)
24. [024-linear-diagnostics-log-and-refresh-visibility.md](completed/024-linear-diagnostics-log-and-refresh-visibility.md)
25. [025-test-database-isolation-and-mocking.md](completed/025-test-database-isolation-and-mocking.md)
26. [026-persistence-boundary-and-mocked-tests.md](completed/026-persistence-boundary-and-mocked-tests.md)
27. [027-log-oriented-status-dashboard.md](completed/027-log-oriented-status-dashboard.md)
28. [028-modern-web-top-banner.md](completed/028-modern-web-top-banner.md)
29. [029-linear-workflow-state-model.md](completed/029-linear-workflow-state-model.md)
30. [030-docker-image-modes.md](completed/030-docker-image-modes.md)
31. [031-runtime-proxy-env-support.md](completed/031-runtime-proxy-env-support.md)
32. [032-workflow-profile-policy-schema.md](completed/032-workflow-profile-policy-schema.md)
33. [033-linear-task-read-update-tools.md](completed/033-linear-task-read-update-tools.md)
34. [034-codex-sensitive-env-scrub.md](completed/034-codex-sensitive-env-scrub.md)
35. [035-profile-aware-prompt-builder.md](completed/035-profile-aware-prompt-builder.md)
36. [036-orchestrator-profile-activity-dispatch.md](completed/036-orchestrator-profile-activity-dispatch.md)
37. [037-refinement-workflow-execution.md](completed/037-refinement-workflow-execution.md)
38. [038-implementation-workflow-execution.md](completed/038-implementation-workflow-execution.md)
39. [039-linear-skill-and-docs-restricted-tools.md](completed/039-linear-skill-and-docs-restricted-tools.md)
40. [040-workflow-page-validate-after-edit.md](completed/040-workflow-page-validate-after-edit.md)
41. [041-project-agnostic-workflow-template.md](completed/041-project-agnostic-workflow-template.md)
42. [042-project-bootstrap-config-schema.md](completed/042-project-bootstrap-config-schema.md)
44. [044-stage-specific-execution-profiles.md](completed/044-stage-specific-execution-profiles.md)
45. [045-database-inline-profile-normalization.md](completed/045-database-inline-profile-normalization.md)
46. [046-profile-prompt-mode-clarity.md](completed/046-profile-prompt-mode-clarity.md)
47. [047-workflow-import-first-configuration-page.md](completed/047-workflow-import-first-configuration-page.md)
48. [048-workflow-tracker-fixed-fields-cleanup.md](completed/048-workflow-tracker-fixed-fields-cleanup.md)
49. [049-workflow-profile-editor-slice.md](completed/049-workflow-profile-editor-slice.md)
50. [050-workflow-phase-state-routing-editor.md](completed/050-workflow-phase-state-routing-editor.md)
51. [051-workflow-save-feedback-state.md](completed/051-workflow-save-feedback-state.md)
52. [052-remove-memory-tracker-path.md](completed/052-remove-memory-tracker-path.md)
53. [053-codex-app-server-startup-error-context.md](completed/053-codex-app-server-startup-error-context.md)
54. [054-running-session-state-history.md](completed/054-running-session-state-history.md)
55. [055-linear-workflow-state-preflight-validation.md](completed/055-linear-workflow-state-preflight-validation.md)
56. [056-linear-status-bootstrap-button.md](completed/056-linear-status-bootstrap-button.md)
57. [057-require-project-repository-url.md](completed/057-require-project-repository-url.md)
58. [058-clean-workspace-on-start.md](completed/058-clean-workspace-on-start.md)
59. [059-project-bootstrap-before-hooks.md](completed/059-project-bootstrap-before-hooks.md)
60. [060-workflow-hooks-config-ui.md](completed/060-workflow-hooks-config-ui.md)
61. [061-ready-to-in-progress-on-codex-start.md](completed/061-ready-to-in-progress-on-codex-start.md)
62. [062-run-detail-observability-pages.md](completed/062-run-detail-observability-pages.md)
63. [063-listening-control-and-force-stop-agents.md](completed/063-listening-control-and-force-stop-agents.md)
64. [064-bootstrap-noninteractive-streaming-diagnostics.md](completed/064-bootstrap-noninteractive-streaming-diagnostics.md)
65. [065-linear-reference-attachment-linking.md](completed/065-linear-reference-attachment-linking.md)
66. [066-session-history-observable-details.md](completed/066-session-history-observable-details.md)
67. [067-session-history-notification-coalescing.md](completed/067-session-history-notification-coalescing.md)
68. [068-generated-git-clone-timeout-diagnostics.md](completed/068-generated-git-clone-timeout-diagnostics.md)
69. [069-run-phase-boundary-logs.md](completed/069-run-phase-boundary-logs.md)
70. [070-dashboard-listening-controls.md](completed/070-dashboard-listening-controls.md)
71. [071-codex-mcp-elicitation-hard-stop.md](completed/071-codex-mcp-elicitation-hard-stop.md)
72. [072-expose-workflow-state-parameters.md](completed/072-expose-workflow-state-parameters.md)
73. [073-merge-branch-from-linear-branchname.md](completed/073-merge-branch-from-linear-branchname.md)

## Plan Guidelines

Each plan should include:

- Goal
- Status
- Background
- Scope
- Out of Scope
- Acceptance Criteria
- Test Cases
- Implementation Notes
- Verification
- Completion Deviations
- Dependencies
- Handoff Notes

When implementation starts, keep the plan current. If the implementation discovers important deviations, tradeoffs, or follow-up work, write them into the plan before marking it complete.

`Completion Deviations` should be present even before work starts. Leave it as `None yet` until implementation begins, then record any meaningful difference between the plan and the delivered code.

## Active Plans

None.
