# 087 Move Linear Discovery Into Settings

## Goal

Move Linear configuration discovery out of the Linear Diagnostics page and into the Settings area, so the feature matches the operator workflow: discover Linear-side values while configuring projects/workflow settings, then use Diagnostics only to validate the active runtime configuration.

## Status

Completed.

## Background

`/diagnostics/linear` currently mixes two different jobs:

- Diagnostics: validate the active Symphony runtime configuration against Linear.
- Discovery: fetch read-only Linear projects, teams, and workflow states to help fill Settings.

From a user perspective, discovery is configuration assistance. The operator needs it while editing project Linear slug and workflow state lists, not after leaving Settings for a diagnostics page. Keeping discovery in Diagnostics also makes the page harder to reason about: the page contains validation results, bootstrap actions, and configuration migration data in one surface.

The product model should be:

- Settings is where configuration is edited and assisted.
- Linear Diagnostics is where the saved active configuration is checked.
- Linear status bootstrap may remain Diagnostics because it acts on validation failures for the active configuration.

This plan supersedes the placement decision in `085-linear-discovery-assistant.md` that treated Diagnostics as the natural home for discovery. The discovery data boundary can remain; the UI placement should change.

## Scope

- Add Linear discovery UI to Settings, preferably in the Settings Projects tab because Linear project slug is project-specific.
- Expose discovered Linear project candidates next to project settings fields:
  - project name,
  - slug,
  - URL,
  - associated teams where available.
- Expose discovered teams and workflow states in a Settings-adjacent area that is useful while editing Workflow settings:
  - either a discovery panel in `/settings/projects` with links/copy controls for Workflow state lists,
  - or a dedicated Settings tab if the Projects tab becomes too dense.
- Keep discovery read-only by default.
- Keep copy controls for:
  - project slug,
  - state lists.
- If applying values is implemented in this slice, make every apply explicit:
  - applying a project slug updates the selected project through existing project persistence,
  - applying state lists saves through existing workflow settings persistence,
  - show the same saving/saved/error feedback pattern as other Settings forms.
- Remove the Linear Configuration Discovery section and fetch button from `/diagnostics/linear`.
- Keep `/diagnostics/linear` focused on:
  - runtime source,
  - tracker configuration visibility,
  - API/project/state/candidate issue probes,
  - missing status bootstrap.
- Reuse `SymphonyElixir.Linear.Discovery`; do not duplicate GraphQL queries in the LiveView.
- Update tests and docs that currently describe discovery as part of Diagnostics.

## Out of Scope

- Do not make tracker kind editable.
- Do not make Linear endpoint editable.
- Do not add non-Linear tracker providers.
- Do not auto-import Linear configuration on page load.
- Do not silently overwrite project or workflow settings.
- Do not reintroduce workflow file editing, templates, or YAML import flows.
- Do not require a fully valid active workflow before discovery can fetch Linear metadata, as long as the Linear API token is available.
- Do not redesign the whole Settings page in this plan beyond placing discovery in the correct workflow.

## Acceptance Criteria

- [x] Settings exposes a clear Linear discovery action.
- [x] The discovery action runs only on user click.
- [x] Discovery success displays Linear projects, teams, and workflow state names inside Settings.
- [x] Discovery token/API errors are shown inside Settings without breaking existing forms.
- [x] `/diagnostics/linear` no longer renders `Linear Configuration Discovery`.
- [x] `/diagnostics/linear` no longer renders `Fetch Linear configuration`.
- [x] Diagnostics refresh and missing-status bootstrap still work.
- [x] Project slug discovery is presented where project settings are edited.
- [x] Workflow state discovery is presented where workflow state settings are edited or clearly linked from the discovery panel.
- [x] Copy controls remain available for project slugs and state lists.
- [x] Apply controls are intentionally not implemented; discovery remains read-only and copy-first.
- [x] Tests cover discovery success/error behavior in Settings.
- [x] Tests cover that Diagnostics no longer contains discovery controls.
- [x] User docs describe discovery as a Settings helper, not a Diagnostics feature.

## Test Cases

- Settings Projects page:
  - renders a Linear discovery action,
  - initially shows no discovery data,
  - clicking discovery with fake Linear data renders project slug candidates,
  - clicking discovery with missing token shows an inline error,
  - existing project create/edit forms remain usable.
- Settings Workflow page or discovery panel:
  - renders discovered state names in a copyable form,
  - derives active/terminal/review suggestions consistently with existing discovery logic.
- Linear Diagnostics page:
  - renders diagnostics sections,
  - does not render `Linear Configuration Discovery`,
  - does not render `Fetch Linear configuration`,
  - still supports `Refresh`,
  - still supports status bootstrap when required.
- Discovery boundary:
  - existing `SymphonyElixir.Linear.Discovery` tests continue to cover split Linear queries and error payload handling.

## Implementation Notes

- Prefer keeping discovery state local to the Settings LiveView assign; do not persist raw discovery results.
- Use existing `Discovery.fetch/0` and fake client support from Linear diagnostics tests.
- If the Settings LiveView becomes too large, extract rendering helpers instead of mixing large discovery tables into the main template.
- The default first implementation can be copy-only. Direct apply can be a follow-up if it risks entangling project settings and workflow settings too much.
- Keep Settings layout compact:
  - discovery output must stay inside the Settings content card,
  - no floating status text between cards,
  - no duplicate fetch buttons for the same action.
- Be careful with the existing no-legacy-route direction. Do not add redirects or keep duplicate product surfaces.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

- Delivered copy-only discovery in `/settings/projects`; direct apply controls were not added. This keeps discovery read-only and avoids introducing a cross-tab mutation path before the Settings save model is clearer.
- Workflow state discovery is presented in the Projects discovery panel with copy controls, not as a separate Workflow tab panel. This keeps the first relocation compact while still putting discovery in Settings.

## Dependencies

- Existing `SymphonyElixir.Linear.Discovery` read-only fetch/normalization boundary.
- Existing Settings tabs and project/workflow persistence boundaries.
- Existing Linear API token resolution from environment.

## Handoff Notes

The important product correction is ownership: Linear discovery is not a diagnostics feature. It is a Settings assistant for configuration and migration. Diagnostics should validate what Settings saved; it should not be the primary place to discover what to put into Settings.
