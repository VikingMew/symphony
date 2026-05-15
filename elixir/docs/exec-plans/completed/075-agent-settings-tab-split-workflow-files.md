# 075 Agent Settings Tab And Split Workflow Files

## Goal

Move profile editing out of the main workflow page into a dedicated `Agent Settings` tab, and make file-backed workflow configuration support a split package made of `workflow.yml` and `profiles.yml`.

## Status

Completed.

Superseded by plan 076 for prompt ownership: `profiles.yml` now owns both profiles and `base_prompt`.

## Background

The `/workflows` page currently mixes runtime workflow routing, project/bootstrap settings, prompt body, and execution profile settings in one long form. Profiles are agent behavior settings: executor type, prompt composition, allowed update fields, target states, and merge executor options. Keeping those controls in the workflow routing page makes the page harder to scan and hides the difference between workflow state routing and agent execution policy.

File-backed configuration is split by responsibility. The direction is to keep workflow routing/runtime policy in `workflow.yml` and execution profile policy in `profiles.yml`.

## Scope

- Add a top-level `Agent Settings` tab/page in the Web navigation.
- Render all profile setting controls only on `Agent Settings`, not inside the main `/workflows` body.
- Keep profile fields in the same underlying draft so saving from either tab still creates one complete workflow version.
- Keep profile options available to workflow state routing selects on `/workflows`.
- Add file-backed split package support:
  - `workflow.yml` contains the non-profile YAML config.
  - `profiles.yml` contains the top-level `profiles` map.
- Update the checked-in local workflow files to use the split package.
- Add tests covering the new tab, absence of profile panels from `/workflows`, presence of profile panels on `/agent-settings`, and split package loading.

## Out of Scope

- Database schema changes for separate profile records.
- Adding profile creation/deletion controls.
- Redesigning the profile card internals beyond moving them to the new tab.
- Changing runtime profile semantics.

## Acceptance Criteria

- [x] Navigation includes `Agent Settings`.
- [x] `/workflows` no longer renders profile editor panels.
- [x] `/agent-settings` renders the profile editor panels and save button.
- [x] Saving profile settings still serializes profiles into the active workflow version.
- [x] `/workflows` routing selects still list known profiles.
- [x] File-backed startup can load `workflow.yml` plus `profiles.yml`.
- [x] The repository's local workflow config is split into `workflow.yml` and `profiles.yml`.
- [x] Focused tests, full test suite, lint, build, and diff check pass.

## Test Cases

- Render `/workflows`; assert workflow routing controls are present and profile prompt editor labels are absent.
- Render `/agent-settings`; assert `Agent Settings`, profile names, executor controls, prompt mode controls, and allowed update controls are present.
- Submit the structured workflow form from the agent settings page after changing a profile prompt; assert the persisted raw workflow includes the changed `profiles.<id>.prompt.template`.
- Load a temporary split package with `workflow.yml` and `profiles.yml`; assert config has `workflow` and config has `profiles`.

## Implementation Notes

- Reuse `AdminLive` and the existing workflow draft assigns for both tabs so there is still one source of truth.
- Add an `:agent_settings` LiveView action and route instead of a client-only tab; this keeps URLs bookmarkable and fits the current Phoenix routing style.
- Extract the repeated workflow header/save/import chrome and profile editor markup into helpers only if it reduces duplication without obscuring the form behavior.
- Treat `profiles.yml` as either a direct profiles map or a map with a top-level `profiles` key, so the file is ergonomic and still explicit.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/core_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Dependencies

- Existing `/workflows` structured draft form in `SymphonyElixirWeb.AdminLive`.
- Existing `SymphonyElixir.Workflow` file-backed loader.

## Handoff Notes

This task separates operational concepts without splitting persisted database workflow versions yet. The UI can show workflow routing and agent execution policy on different tabs while still saving a complete workflow package for the current persistence layer.
