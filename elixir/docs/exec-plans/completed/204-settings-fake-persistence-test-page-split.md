# 204 Settings Fake Persistence Test Page Split

## Goal

Split `settings_fake_persistence_test.exs` by settings page or workflow so the settings test suite no longer recreates a large catch-all file.

## Status

Completed.

## Background

Completed plan 180 split settings and observability fake-persistence tests out of a broader web test file. The new `test/symphony_elixir_web/live/settings_fake_persistence_test.exs` is still roughly 1,600 lines.

The split improved top-level ownership, but settings itself now needs finer page/workflow ownership.

## Scope

- Inventory settings test groups by page or workflow.
- Move one coherent group into a focused test file first.
- Keep shared setup helpers small and explicit.
- Preserve route behavior and assertions.
- Align with completed plan 200 if settings routes move to a dedicated LiveView.

## Out of Scope

- Changing settings UI behavior.
- Changing import/runtime mismatch semantics.
- Rewriting fake persistence.
- Moving observability tests.

## Acceptance Criteria

- `settings_fake_persistence_test.exs` loses at least one complete settings workflow group.
- New test file names describe the page/workflow under test.
- Shared helpers do not become a new hidden catch-all.
- Existing settings coverage remains intact.
- The split makes completed plan 200 easier rather than harder.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir_web/live/settings_fake_persistence_test.exs`
- `mise exec -- mix test test/symphony_elixir_web/live/settings_*_test.exs`
- `wc -l test/symphony_elixir_web/live/settings_fake_persistence_test.exs test/symphony_elixir_web/live/settings_*_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

None.

## Dependencies

- Completed plan 180 for web fake persistence settings/observability split.
- Completed plan 200 for settings route split.

## Handoff Notes

Keep the first split mechanical and small. The point is to stop the replacement file from becoming the new dumping ground.

Completed verification:

- 2026-05-22: `mise exec -- mix format`
- 2026-05-22: `mise exec -- mix test` (587 tests, 0 failures, 2 skipped)
- 2026-05-22: `mise exec -- mix exec_plans.check`

