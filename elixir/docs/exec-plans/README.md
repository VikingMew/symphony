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
