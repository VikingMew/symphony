# 085 Linear Discovery Assistant

## Goal

Add a Linear diagnostics page action that fetches useful Linear-side configuration candidates, such as available projects, teams, workflow states, and assignable users, so a new Symphony setup can copy or apply correct values with less manual migration work.

## Context

The current Linear page validates the active workflow configuration and can bootstrap missing statuses, but it assumes the operator already knows the correct Linear project slug and state names. During migration this creates avoidable friction:

- Project slug is easy to mistype.
- Active, terminal, review, and merge state names must match Linear exactly.
- Users need to leave Symphony to inspect available projects and workflow states.
- The diagnostics page already has Linear API access and is the natural place to expose read-only discovery data.

Tracker kind and endpoint are not product settings. They remain fixed to Linear and the default Linear GraphQL endpoint. This plan must not reintroduce editable tracker kind or endpoint fields.

## Scope

- Add a button on `/diagnostics/linear`, for example `Fetch Linear configuration`.
- Use the configured Linear API token to fetch read-only Linear metadata:
  - teams,
  - projects with slug/id/name/url,
  - workflow states grouped by team or project team,
  - assignable users if the Linear API exposes a suitable query through the existing client boundary.
- Render the fetched data in a clear section on the Linear page.
- Highlight values useful for Symphony configuration:
  - project slug candidates,
  - available state names,
  - likely active states,
  - likely terminal states,
  - likely human review states.
- Provide low-friction copy/apply controls where safe:
  - Copy project slug.
  - Copy state list.
  - Optionally apply selected project slug to the current/default project settings.
  - Optionally apply selected state lists to Workflow settings.
- Keep apply actions explicit and confirmation-based. A discovery refresh must not mutate settings.
- Persist settings changes through existing project/workflow persistence paths if apply actions are included.
- Show partial failure states: token missing, API failed, no teams, no projects, no states.
- Keep existing diagnostics and status-bootstrap behavior working.

## Non-Goals

- Do not make tracker kind editable.
- Do not make Linear endpoint editable.
- Do not add another tracker provider.
- Do not import Linear workflow configuration automatically on page load.
- Do not silently overwrite active workflow settings.
- Do not add file-based workflow editing or template generation.
- Do not require a configured active workflow before discovery can fetch global projects/teams if the token is available.

## Design Decisions To Validate During Implementation

- Discovery should work even when setup is incomplete, as long as a Linear API token can be resolved.
- The page should distinguish read-only discovered data from active Symphony settings.
- Project slug application belongs to Settings / Projects because project slug is project-specific.
- State list application belongs to Settings / Workflow because state policy is currently shared.
- If direct apply creates too much coupling for this slice, ship copy-only controls first and record apply as a follow-up.
- The Linear API client should expose named discovery functions instead of embedding ad hoc GraphQL strings directly in the LiveView.

## Acceptance Criteria

- [x] `/diagnostics/linear` has a visible action to fetch Linear configuration candidates.
- [x] The action calls Linear only when the user clicks it.
- [x] Token-missing state shows a clear message and does not crash.
- [x] API failures show a clear error and preserve the rest of the diagnostics page.
- [x] Successful discovery displays Linear teams.
- [x] Successful discovery displays Linear projects with slug, name, id, and URL where available.
- [x] Successful discovery displays workflow state names grouped by relevant team/project context.
- [x] Kind displays as fixed `linear` and endpoint displays as the fixed Linear GraphQL endpoint; neither is editable.
- [x] Discovery results include copy controls for project slug and state lists, or an equivalent low-friction UI.
- [x] If apply controls are included, each apply path saves through the current persistence boundary and shows success/error feedback.
- [x] Existing Linear diagnostics refresh and missing-status bootstrap still work.
- [x] Tests cover success, token missing, API error, and setup-incomplete discovery behavior.

## Completion Notes

- Implemented copy-first discovery. Direct apply controls were intentionally not included in this slice to avoid silently mixing read-only diagnostics with settings mutation.
- Added `SymphonyElixir.Linear.Discovery` as a read-only normalization boundary.
- Extended the Linear client with `graphql_with_auth/5` so discovery can reuse the existing GraphQL request path with an explicitly resolved tracker token.

## Test Plan

- Add Linear client fake responses for discovery queries.
- Add unit tests for new discovery normalization:
  - teams/projects/states are normalized into stable display data,
  - missing fields do not crash rendering,
  - likely state groups are derived only from explicit names or conservative heuristics.
- Add LiveView tests for `/diagnostics/linear`:
  - button is rendered,
  - click with missing token shows an error,
  - click with fake Linear data renders teams/projects/states,
  - existing diagnostics cards remain visible after discovery,
  - kind/endpoint remain fixed and non-editable.
- If apply controls are implemented, add LiveView tests that:
  - applying a project slug updates the current/default project,
  - applying state lists saves a new workflow settings version,
  - save failures show existing toast/error behavior.
- Run:
  - `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
  - `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- Prefer adding a small `SymphonyElixir.Linear.Discovery` module or extending `Linear.Diagnostics` with discovery-only functions if that keeps the boundary simple.
- Reuse `Linear.Client.graphql/3` helpers where possible, but keep queries named and testable.
- Keep discovery result data separate from diagnostics probes so a failed discovery does not make the main diagnostics run look failed.
- Do not store discovery results unless the user explicitly applies a value to settings.
- Keep the UI dense and operational: this is a migration/configuration aid, not a marketing panel.
- Be careful with existing dirty worktree state; this plan should not revert prior database setup, diagnostics, or settings changes.
