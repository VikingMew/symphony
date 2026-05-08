# 052 Remove Memory Tracker Path

## Goal

Remove the `memory` tracker path from Symphony's runtime and test architecture. Tests should use explicit fake/mocked Linear inputs or fake persistence, not a real alternate tracker adapter named `memory`.

The Web product direction is Linear-backed workflow configuration. A hidden `memory` tracker is confusing, can leak into saved database workflow versions, and makes diagnostics look like the operator selected a tracker kind they never saw.

## Status

Completed.

## Background

`memory` currently exists as a local/test tracker adapter. It can fetch in-memory issues from application environment and emit messages when comments or state updates are requested.

That abstraction was useful early on, but it now conflicts with the product model:

- `/workflows` no longer exposes tracker kind.
- Web workflow versions should always be Linear workflow versions.
- Linear diagnostics should not encounter `tracker.kind = memory` from a user-created database workflow.
- Tests should not need a second runtime tracker implementation to avoid Linear network calls.

The recent Web save bug exposed this clearly: because the UI stopped submitting `tracker_kind`, save code defaulted to `memory`, and diagnostics skipped every Linear check. Even though that specific bug is fixed, keeping `memory` as a valid runtime tracker leaves the same class of error available.

## Scope

- Remove `SymphonyElixir.Tracker.Memory`.
- Remove `"memory"` from tracker adapter selection.
- Remove `"memory"` as an accepted configured tracker kind.
- Change setup-required workflow fallback to use a Linear-shaped configuration or a setup-only sentinel that cannot be saved as a runtime tracker.
- Ensure `/workflows` empty/setup drafts serialize to `tracker.kind = linear`.
- Rewrite tests that currently use `tracker_kind: "memory"` to use one of:
  - fake Linear client module responses;
  - fake persistence workflow versions;
  - direct Orchestrator test hooks with supplied issue lists;
  - explicit mocks/stubs at the tracker boundary.
- Remove application env keys:
  - `:memory_tracker_issues`
  - `:memory_tracker_recipient`
- Update diagnostics tests so non-Linear tracker skip behavior is no longer represented by `memory`.
- Update docs and execplan notes that mention memory tracker as an operator-visible/runtime path.

## Out of Scope

- Removing fake persistence.
- Removing fake Linear client modules used by tests.
- Removing setup-required dashboard boot behavior.
- Adding support for other real tracker providers.
- Changing Linear API semantics.

## Acceptance Criteria

- `rg "Tracker.Memory|memory_tracker|tracker_kind: \"memory\"|kind.*memory"` returns no runtime/test dependency except historical completed docs if intentionally preserved.
- `SymphonyElixir.Tracker.adapter/0` has no memory branch.
- `Config.settings!/0` rejects `tracker.kind = memory`.
- Setup-required Web mode still boots without a workflow file or active database workflow.
- Saving from `/workflows` can never create `tracker.kind = memory`.
- Tests that need candidate issues receive them from fake Linear client or direct injected inputs.
- Linear diagnostics never skip because of `tracker.kind = memory`.
- Full test suite passes without `:memory_tracker_issues` or `:memory_tracker_recipient`.

## Test Cases

- Parse a workflow with `tracker.kind: memory`; assert config validation rejects it.
- Boot database workflow source with no file and no active workflow; assert setup-required page renders and the draft save path serializes `tracker.kind = linear`.
- Run tracker adapter tests with fake Linear client and assert reads/mutations delegate to Linear adapter.
- Run orchestrator reconciliation tests with directly supplied issue lists or fake Linear client responses instead of memory tracker state.
- Run missing-running-issue test without `:memory_tracker_issues`.
- Run Linear diagnostics against setup-required/no-workflow state and assert it reports setup required or missing configuration, not memory tracker skip.

## Implementation Notes

- Start by deleting the memory adapter from production selection, then fix compiler/test failures one group at a time.
- Prefer dependency injection already present in tests, such as fake Linear client modules, over adding a new generic tracker mock layer.
- Where tests only need reconciliation behavior, call the test helper functions that accept issue lists directly instead of starting a tracker-backed orchestrator.
- If a setup-required workflow still needs a config object for rendering, use `tracker.kind = linear` with placeholder Linear fields and keep `setup_required: true` as the signal that it is not runnable yet.
- Do not introduce another hidden tracker name such as `mock`, `fake`, or `test` into workflow config. Mocking belongs in tests, not in persisted workflow packages.
- Keep historical completed execplans intact unless they actively mislead current setup docs.

## Verification

- [x] `mise exec -- mix format`
- [x] `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/workflow_store_fake_persistence_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- [x] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [x] `mise exec -- mix test`
- [x] `mise exec -- mix lint`
- [x] `mise exec -- mix build`
- [x] `git diff --check`
- [x] `rg "Tracker.Memory|memory_tracker|tracker_kind: \"memory\"|kind.*memory" lib test config`
- [x] `mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 0`

## Completion Deviations

The unsupported tracker diagnostics test now uses a generic unsupported tracker value instead of preserving `memory` as a test fixture string. This keeps the runtime/test tree free of memory tracker references while still covering the error path.

Startup terminal workspace cleanup now validates the active workflow configuration before contacting Linear. This prevents an incomplete Linear setup from crashing application boot with a Req/Finch URL error after the memory fallback path is removed.

Repeated dispatch-loop configuration errors are logged once per distinct reason. Existing local databases may still contain old `tracker.kind = "memory"` workflow versions, but they now start as a visible configuration error instead of crashing or repeatedly logging the same validation failure.

Existing database workflow versions created before this correction are normalized at runtime and in the `/workflows` form boundary: legacy `tracker.kind = "memory"` is treated as Linear with the default Linear endpoint and `$LINEAR_API_KEY`. This is a compatibility migration for old persisted data, not a restored memory tracker path.

## Dependencies

- Depends on Task 048's decision that `/workflows` does not expose tracker kind.
- Depends on Task 051 save feedback only for operator clarity; the memory removal itself is independent.
- Related to fake persistence and fake Linear client testing patterns from earlier persistence boundary work.

## Handoff Notes

This task is a direction correction. Do not replace `memory` with another persisted tracker kind for tests. Tests should mock inputs and boundaries directly, while real workflow configuration remains Linear-shaped.
