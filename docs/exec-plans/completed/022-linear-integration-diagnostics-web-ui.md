# Task 022: Linear Integration Diagnostics Web UI

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 005, Task 007, Task 021
**Created**: 2026-05-01

## Goal

Add a Web UI diagnostics surface that lets an operator verify whether Symphony's Linear integration is complete and usable before agents start running.

The UI must cover at least Linear API connectivity, configured project slug validity, configured workflow states, current candidate task discovery, and the latest relevant Linear issues that Symphony would act on.

## Background

Symphony can now run as a Web service with authentication, SQLite-backed workflow configuration, workflow editing, and dashboard navigation. However, a user still cannot tell from the Web UI whether the Linear side is correctly wired:

- Is the Linear API token present?
- Does the token authenticate successfully?
- Does the configured `project_slug` resolve to a real Linear project?
- Do the configured active and terminal states exist for that project/team?
- Which issues would the current polling configuration fetch?
- Are issues filtered out because of assignee, state, blockers, labels, or missing config?

Without these checks, a login/dashboard that "works" can still hide a broken Linear setup. Operators need a first-class diagnostic page so they can validate the integration from the browser instead of reading logs or manually running GraphQL queries.

## Scope

- Add a Web UI entry for Linear diagnostics.
- Expose the entry through the shared navigator added in Task 021.
- Add the navigator item as a first-class top-level entry, not as a hidden link inside `Settings`.
- Use a stable route and label for the navigation entry:
  - Route: `/diagnostics/linear`
  - Label: `Linear`
- Provide a read-only diagnostics panel for the active workflow's tracker config.
- Add a backend diagnostics module that can run focused Linear probes.
- Add a probe for Linear API authentication using a low-cost GraphQL query such as `viewer`.
- Add a probe that resolves the configured project slug and returns basic project metadata.
- Add a probe that verifies configured active and terminal workflow state names exist.
- Add a probe that fetches current candidate issues using the same tracker configuration the orchestrator uses.
- Show a compact table of relevant issues including identifier, title, state, assignee presence, labels, blockers, updated time, and URL.
- Show raw failure reasons in operator-friendly text while not exposing the Linear API token.
- Keep diagnostics read-only; no issue mutation should occur.
- Add automated tests with fake Linear client responses.

## Out of Scope

- Editing Linear configuration in this task.
- Creating, updating, assigning, or transitioning Linear issues.
- Full multi-project polling fan-out.
- Storing Linear diagnostic snapshots historically.
- A general-purpose GraphQL console in the Web UI.
- Exposing the Linear API token value or any secret material.

## Acceptance Criteria

- [x] Shared navigation includes a top-level `Linear` entry pointing to `/diagnostics/linear`.
- [x] Authenticated users can open the Linear diagnostics page from the dashboard.
- [x] Unauthenticated users remain blocked by existing auth.
- [x] Page displays whether the active workflow tracker kind is `linear`.
- [x] Page clearly shows missing token, missing project slug, and invalid workflow config states.
- [x] Linear API token probe can distinguish success, missing token, HTTP failure, request failure, and GraphQL errors.
- [x] Project slug probe confirms whether the configured slug resolves.
- [x] State probe lists configured active and terminal states and marks missing names.
- [x] Candidate issue probe uses the same state and assignee filtering semantics as runtime polling.
- [x] Relevant issue table renders current candidate issues with enough metadata to debug why work will or will not start.
- [x] Diagnostics never render the Linear API token or Authorization header.
- [x] Tests cover success and failure cases without calling real Linear.

## Test Cases

- Render diagnostics page with a memory/non-Linear workflow and assert the page says Linear diagnostics are not applicable.
- Render diagnostics page with missing Linear API key and assert token status is failed without exposing the token field.
- Fake a successful `viewer` response and assert API connectivity is marked healthy.
- Fake a Linear HTTP error and assert the status is failed with a sanitized reason.
- Fake a project lookup success for the configured slug and assert project metadata is displayed.
- Fake a project lookup miss and assert the slug is marked invalid.
- Fake workflow state lookup where all configured active and terminal states exist.
- Fake workflow state lookup with one missing active state and assert the missing state is visible.
- Fake candidate issue fetch and assert identifiers, states, labels, blockers, and URLs are rendered.
- Fake candidate issue fetch failure and assert the page keeps rendering other probe results.
- Assert unauthenticated `/diagnostics/linear` requests redirect to login when auth is enabled.
- Assert dashboard/shared navigation includes `href="/diagnostics/linear"` with label `Linear`.

## Implementation Notes

- Use `/diagnostics/linear` as the canonical route.
- Add `{:linear, "Linear", "/diagnostics/linear"}` to the shared navigator from Task 021.
- Do not hide Linear diagnostics inside `/settings`; settings may link to diagnostics, but the navigator must expose it directly.
- Prefer a new module such as `SymphonyElixir.Linear.Diagnostics` for probe orchestration.
- Keep the Linear client boundary injectable through application env or function options so tests do not hit the network.
- Reuse `SymphonyElixir.Linear.Client.graphql/3` and existing fetch functions where that preserves runtime-equivalent behavior.
- If new GraphQL queries are needed, keep them minimal:
  - `viewer { id name email }` or similar safe identity metadata.
  - `project(slugId: $slug)` or equivalent Linear project lookup.
  - team/workflow state lookup scoped through the project.
  - issues query using the same filter shape as polling.
- Normalize diagnostics output into stable maps before rendering; avoid building UI directly from raw GraphQL payloads.
- Redact secrets in all inspect/error paths. Never render token values, full headers, or request payloads containing credentials.
- Use existing dashboard styling: `section-card`, `data-table`, `status-badge`, `status-success`, `status-warning`, and `status-danger`.
- Do not make diagnostics automatically run expensive queries on every LiveView tick. Run once on mount and provide a manual refresh button.
- Candidate issue display should default to a bounded limit, for example 25 or 50 issues.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix lint`
- `mise exec -- mix test test/symphony_elixir/*linear*_test.exs`
- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix test`
- Manual check with a real Linear token: open the diagnostics page, verify API/token/project/state/candidate issue probes.
- Manual check with an invalid token: verify the UI shows a safe failure without exposing the token.

## Completion Deviations

- Implemented `/diagnostics/linear` as a dedicated `LinearDiagnosticsLive` page.
- Added `SymphonyElixir.Linear.Diagnostics` to normalize API, project, state, and candidate issue probes into stable maps.
- Candidate issue diagnostics call the same `fetch_candidate_issues/0` boundary used by the runtime Linear client. Tests inject a fake diagnostics client and do not call the real Linear API.
- Manual checks with a real Linear token and invalid token were not run in this environment.

## Dependencies

- Web UI shell and workflow pages from Task 005.
- Dashboard/admin operational pages from Task 007.
- Shared navigation from Task 021.

## Handoff Notes

- Record the final diagnostics route.
- Record which Linear GraphQL queries are used for probes.
- Record how candidate issue limits are configured.
- Record any remaining cases where runtime polling and diagnostics can disagree.

The final route is `/diagnostics/linear`, exposed as `Linear` in the shared navigator. The probes use `SymphonyLinearDiagnosticsViewer`, `SymphonyLinearDiagnosticsProject`, and the existing candidate issue fetch boundary. Candidate issue display uses the runtime fetch result without adding a new UI-specific limit; the existing Linear client page size remains the limiting behavior.
