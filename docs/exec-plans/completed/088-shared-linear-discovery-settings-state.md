# 088 Shared Linear Discovery State Across Settings

## Goal

Make Linear discovery a shared Settings-level helper so `/settings/projects` and `/settings/workflow` can use the same fetched Linear metadata while the operator moves between tabs.

The operator should fetch Linear once, then use the discovered projects, teams, and states from both Project Settings and Workflow Settings without losing the result or making duplicate Linear API calls.

## Status

Completed.

## Background

Linear access is shared product infrastructure:

- Project Settings needs Linear discovery to choose the correct Linear project slug.
- Workflow Settings needs Linear discovery to choose active, terminal, review, and routed state names.
- Runtime diagnostics validates the saved active configuration, but it should not be the place where operators discover values to paste into Settings.

Task 087 moved discovery into Settings, but the first implementation kept discovery presentation in the Projects tab. That still makes the workflow feel wrong: the operator fetches Linear data while editing Projects, then switches to Workflow and loses the visible context for state lists. Conversely, if Workflow gets its own fetch later, the app risks duplicate buttons, duplicate loading/error states, and two stale snapshots of the same Linear read.

The desired model is:

- Linear discovery is one shared Settings resource.
- Projects and Workflow render the parts of that shared resource relevant to their own settings.
- Fetch state is consistent across tabs: `idle`, `fetching`, `fetched`, or `failed`.
- Discovery remains read-only unless a later plan explicitly adds apply actions.

## Scope

- Introduce a shared Linear discovery state owned by the Settings LiveView, not by an individual tab section.
- Preserve discovery data while switching among Settings tabs in the same LiveView session.
- Render one consistent discovery action/status surface for Settings:
  - `Fetch Linear configuration` when idle or failed,
  - `Fetching...` while the request is in progress,
  - `Fetched at <timestamp>` after success,
  - clear inline error after failure.
- Make `/settings/projects` render project-focused discovery data from the shared snapshot:
  - Linear project name,
  - slug,
  - URL,
  - associated teams,
  - copy project slug.
- Make `/settings/workflow` render workflow-focused discovery data from the same shared snapshot:
  - teams and available state names,
  - suggested active states,
  - suggested terminal states,
  - suggested review states,
  - copy state lists.
- Ensure switching between Projects and Workflow does not clear discovery results.
- Ensure there is one fetch path and one source of truth for loading/error/success status.
- Keep discovery read-only and copy-first in this plan.
- Keep Linear Diagnostics focused on validation of saved active runtime configuration.

## Out of Scope

- Do not add direct apply buttons in this plan.
- Do not persist raw Linear discovery snapshots to the database.
- Do not auto-fetch Linear data on page load.
- Do not add a second fetch button in each tab.
- Do not make tracker kind editable.
- Do not make Linear endpoint editable.
- Do not move API token configuration into the Web UI; token remains environment-driven.
- Do not require an active workflow version before discovery can run.
- Do not change Linear diagnostics probe semantics.
- Do not redesign all Settings layout beyond placing shared discovery where it supports Projects and Workflow.

## Acceptance Criteria

- [x] Settings has exactly one Linear discovery fetch action.
- [x] Clicking fetch once stores one shared discovery snapshot in the Settings LiveView assigns.
- [x] The fetch button shows a clear fetching state while the request is running.
- [x] Successful fetch shows a fetched timestamp/status.
- [x] Failed fetch shows a clear error without clearing unrelated Settings form state.
- [x] Project Settings displays project slug candidates from the shared discovery snapshot.
- [x] Workflow Settings displays state/team candidates from the same shared discovery snapshot.
- [x] Switching from Projects to Workflow after a successful fetch keeps the fetched discovery data visible.
- [x] Switching from Workflow back to Projects keeps the same fetched discovery data visible.
- [x] There is no duplicate discovery fetch button on Projects and Workflow.
- [x] Linear Diagnostics does not render discovery controls or discovery data.
- [x] Discovery stays read-only: copy controls only, no implicit settings mutation.
- [x] Tests cover shared state across tab navigation, success, fetching/fetched copy, and failure.

## Test Cases

- Settings Projects page:
  - initially renders the shared discovery action and no discovery data,
  - fetch with fake Linear data renders project candidates,
  - project create/edit forms remain usable after discovery success,
  - fetch failure shows inline error and keeps project forms visible.
- Settings Workflow page:
  - after a prior fetch in the same LiveView session, renders workflow state candidates without another fetch,
  - shows active/terminal/review suggestions from the shared snapshot,
  - copy controls for state lists remain available.
- Settings tab switching:
  - start on `/settings/projects`,
  - click fetch,
  - navigate to Workflow using the Settings tab link,
  - assert the fetched timestamp/status and workflow-focused discovery data are still visible,
  - navigate back to Projects,
  - assert project-focused discovery data is still the same snapshot.
- Linear Diagnostics page:
  - does not render `Fetch Linear configuration`,
  - does not render project/state discovery tables,
  - still renders diagnostics refresh and probes.
- Discovery boundary:
  - existing `SymphonyElixir.Linear.Discovery` tests remain the source of truth for query splitting, normalization, and suggestions.

## Implementation Notes

- Prefer a single assign shape in `AdminLive`, for example:
  - `:linear_discovery_status` as `:idle | :fetching | :fetched | :failed`,
  - `:linear_discovery` as `nil | {:ok, discovery} | {:error, reason}`,
  - `:linear_discovery_message` for user-facing status.
- Keep `handle_event("fetch_linear_discovery", ...)` as the only fetch path.
- Avoid recomputing or clearing discovery assigns inside `refresh/1` unless the operator explicitly fetches again.
- If `push_patch`/LiveView tab navigation remounts the LiveView and loses assigns, change Settings tab links to LiveView patch navigation or otherwise preserve state within the same LiveView session.
- Extract rendering helpers if needed:
  - shared discovery header/action,
  - project discovery panel,
  - workflow discovery panel.
- Keep copy controls client-side and non-mutating.
- Keep errors readable; do not expose tokens or Authorization headers.
- Keep Settings ownership clear:
  - Projects displays project-owned discovered values,
  - Workflow displays workflow-owned discovered values,
  - Runtime displays runtime/env setup guidance only.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

- LiveView event handling is synchronous, so the implementation uses `phx-disable-with="Fetching..."`
  for visible in-flight feedback rather than persisting a long-lived `:fetching` assign between
  renders.
- Discovery remains session-local to the Settings LiveView. A hard browser reload returns discovery
  to idle, which matches the out-of-scope decision not to persist raw Linear discovery snapshots.
- Project-focused and workflow-focused tables are separate projections of the same fetched snapshot;
  the shared fetch/status panel is rendered only for Projects and Workflow settings.

## Dependencies

- Existing `SymphonyElixir.Linear.Discovery` fetch and normalization boundary.
- Existing Settings LiveView tab structure in `SymphonyElixirWeb.AdminLive`.
- Existing fake Linear client/test support for deterministic discovery results.
- Existing copy-first discovery behavior from Task 087.

## Handoff Notes

The key correction is ownership of the Linear read: discovery is shared across Settings, not owned by Projects or Workflow individually. Projects and Workflow should render different projections of the same fetched snapshot. Diagnostics remains a validation surface for saved runtime config, not a discovery workspace.
