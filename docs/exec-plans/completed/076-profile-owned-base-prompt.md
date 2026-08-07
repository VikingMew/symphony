# 076 Profile Owned Base Prompt

## Goal

Move the shared base prompt out of the workflow-page/runtime-routing surface and make it part of profile configuration. In the split file package, `profiles.yml` owns both agent profiles and the shared `base_prompt`; `workflow.yml` owns runtime, tracker, project, hooks, and state routing.

## Context

The previous split placed runtime/routing in `workflow.yml`, profile definitions in `profiles.yml`, and the base prompt body in a separate Markdown file. That still makes the workflow page responsible for prompt editing and keeps a third runtime configuration file that does not match the current product direction. The UI should present prompt composition where users configure agents: `Agent Settings`. The workflow page should focus on tracker, project/bootstrap, hooks, runtime, Codex, and state routing.

## Scope

- Add top-level `base_prompt` support to `profiles.yml`.
- Prefer `profiles.yml` `base_prompt` when loading a split package.
- Move the base prompt textarea from `/workflows` to `/agent-settings`.
- Update the checked-in split package so the current base prompt lives in `profiles.yml`.
- Make `workflow.yml` the default file-backed CLI entrypoint.
- Remove separate Markdown prompt-file language from user-facing docs.
- Update docs and tests to describe `profiles.yml` as the prompt/profile owner.

## Non-Goals

- Redesigning database workflow version storage.
- Changing how saved database workflow versions store `prompt_body`.
- Redesigning profile prompt rendering order.
- Adding a new prompt template language or profile schema.

## Acceptance Criteria

- [x] `/workflows` no longer renders or submits the base prompt textarea.
- [x] `/agent-settings` renders and saves the base prompt textarea along with profile settings.
- [x] Split file loading uses `profiles.yml` `base_prompt` when present.
- [x] The repository's `profiles.yml` contains the current base prompt.
- [x] `workflow.yml` is the default file-backed CLI entrypoint.
- [x] The repository no longer has a separate Markdown prompt file in the runtime package.
- [x] Documentation says `profiles.yml` contains profiles plus base prompt and does not introduce a separate Markdown compatibility/fallback concept.

## Test Plan

- Render `/workflows`; assert workflow runtime fields are present and `workflow[prompt_body]` is absent.
- Render `/agent-settings`; assert profile controls and `workflow[prompt_body]` are present.
- Save `/agent-settings` with changed profile prompt and changed base prompt; assert both are persisted in the generated workflow version.
- Load a split package where `profiles.yml` has `base_prompt`; assert the loaded prompt comes from `profiles.yml`.
- Run CLI tests; assert default file-backed path is `workflow.yml`.
- Run targeted tests, full test suite, lint, build, and whitespace check.

## Implementation Notes

- Keep `Workflow.to_markdown/2` unchanged as the database serialization format for complete workflow versions.
- Normalize `profiles.yml` in both explicit form:

  ```yaml
  base_prompt: |
    ...
  profiles:
    implementation:
      ...
  ```

  `profiles.yml` must use the explicit package shape; do not keep the older direct-profile-map shape.
- The UI still edits one workflow draft; only the tab ownership changes.
