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
