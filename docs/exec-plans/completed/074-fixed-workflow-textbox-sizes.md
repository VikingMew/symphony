# 074 Fixed Workflow Textbox Sizes

## Goal

Make all editable text boxes in the Web workflow editor stable fixed-size controls. Text entry must not resize panels, profile cards, routing sections, or the overall `/workflows` layout as content grows.

## Status

Completed.

## Background

The workflow page now has many editable text areas: active/terminal states, setup/cleanup commands, lifecycle hooks, profile prompts, allowed target states, human review states, and the base prompt. These are operational controls, not free-form document editors. If their height changes with content or browser resize handles, the page becomes hard to scan and the sections move around while editing.

The project UI already aims for dense, predictable controls. Fixed text-box dimensions match that direction: the user edits in-place, and long content scrolls inside the control instead of changing the surrounding layout.

## Scope

- Make normal `input` and `select` controls use a consistent fixed height.
- Make all `textarea` controls non-resizable with explicit fixed heights.
- Add semantic textarea size classes for:
  - compact lists and short hooks;
  - command/state lists;
  - profile prompt templates;
  - the base prompt.
- Apply those classes to every workflow textarea in `AdminLive`.
- Ensure overflowing textarea content scrolls inside the control.
- Keep responsive width behavior intact: controls still fill their parent column, but height remains fixed.
- Add lightweight tests that the workflow page renders the fixed-size classes and the served dashboard CSS contains the fixed-size rules.

## Out of Scope

- Changing workflow form fields or saved workflow schema.
- Adding rich editors or code editor widgets.
- Changing prompt semantics.
- Redesigning profile or routing layout beyond textbox sizing.
- Browser automation screenshots unless a later visual bug requires it.

## Acceptance Criteria

- [x] All `/workflows` textarea elements have a fixed-size class.
- [x] Textareas use `resize: none`.
- [x] Textareas use `overflow: auto`.
- [x] Base prompt, profile prompt, lists, hooks, and command fields have stable fixed heights.
- [x] Inputs/selects have a consistent fixed control height.
- [x] Existing workflow form save/import tests still pass.
- [x] Full test suite and lint pass.

## Test Cases

- Render `/workflows` and assert the relevant textarea classes are present:
  - workflow textarea base class;
  - compact textarea class;
  - medium/list textarea class;
  - profile prompt textarea class;
  - base prompt textarea class.
- Fetch `/dashboard.css` and assert it defines:
  - fixed control height for inputs/selects;
  - textarea resize disabled;
  - textarea overflow auto;
  - semantic fixed heights.
- Submit the structured workflow form and assert save behavior is unchanged.

## Implementation Notes

- Prefer CSS classes over inline styles so the fixed-size contract is visible and testable.
- Do not use `height: auto` or JS autosizing.
- Do not rely on `rows` as the sizing contract; keep rows only as harmless fallback where already present.
- Use `box-sizing: border-box` so padding and borders do not inflate fixed dimensions.
- Use `min-height` and `max-height` equal to the same value for each semantic textarea size.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix test test/symphony_elixir/app_server_test.exs`
- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

- Full-suite validation exposed existing macOS `/var` versus `/private/var` workspace path assumptions in tests. I stabilized those tests to compare against `SymphonyElixir.PathSafety.canonicalize/1`; runtime behavior was unchanged.
- Full-suite validation also exposed a brittle startup-timeout test window. I kept the runtime behavior unchanged and widened the test timeout enough to reliably capture the intended bounded startup output.

## Dependencies

- Existing `/workflows` structured form in `SymphonyElixirWeb.AdminLive`.
- Existing static `dashboard.css` serving path.
- Existing fake persistence Web tests.

## Handoff Notes

The desired behavior is fixed-size operational controls. If a future editor needs document-style expansion, add a specific editor component for that use case instead of making all workflow text boxes auto-grow again.
