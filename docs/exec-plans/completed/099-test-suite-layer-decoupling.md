# 099 Test Suite Layer Decoupling

## Goal

Decouple the Elixir test suite by test responsibility. UI tests should test rendered UI behavior only, business logic tests should test domain behavior only, and all cross-boundary dependencies should be mocked through explicit adapters. The default test suite should not start or exercise a real SQLite database, run Ecto migrations, or depend on real persistence side effects.

## Status

Completed.

## Background

The project has moved toward explicit runtime boundaries: database-backed workflow versions are the product source of truth, Linear access is shared runtime configuration, and web Settings pages edit structured drafts. The test suite has not fully followed that direction. Several tests still mix LiveView rendering, persistence behavior, database setup, runtime orchestration, and external integration assumptions in one assertion path.

That makes failures hard to interpret. A UI test can fail because a database migration changed, a business test can fail because HTML structure changed, and "database isolation" tests preserve a real DB path that the current direction explicitly wants to avoid in ordinary tests. The result is slower feedback and unclear ownership.

The desired model is:

- UI tests render LiveViews/controllers against fake providers and assert only user-visible UI state, events, forms, toasts, navigation, and call boundaries.
- Business/domain tests call pure modules or service functions with fake adapters and assert data transformations, state transitions, validations, and command decisions.
- Persistence implementation tests should not use a real database in the default suite. If persistence behavior needs coverage, cover it through contract tests against a mock repository/adapter, or move real database smoke checks behind an explicit non-default integration target.
- No test should use a real database just to make application wiring convenient.

## Scope

- Audit all tests under `elixir/test` and classify them as:
  - UI/rendering tests;
  - business/domain tests;
  - adapter contract tests;
  - integration/smoke tests that should not run in the default suite.
- Remove default-suite tests that start `SymphonyElixir.Repo`, create SQLite files, run migrations, or rely on Exqlite behavior.
- Replace real persistence dependencies in UI tests with `FakePersistence` or a narrower purpose-built mock.
- Replace business tests that currently use LiveView or controller paths with direct module calls and fake dependencies.
- Introduce or tighten explicit mock boundaries for:
  - persistence;
  - workflow store/current active workflow;
  - Linear client/discovery;
  - Codex app server/client;
  - workspace/git command execution;
  - orchestrator/runtime snapshots.
- Split large mixed tests such as web/persistence/orchestrator flows into smaller tests where each layer owns only its own behavior.
- Keep fixture data minimal and semantic; fixtures should model inputs/outputs, not act as golden snapshots of large HTML or database state.
- Update test support modules so default setup never starts a real database unless a test opts into a clearly named non-default integration profile.
- Update docs/test guidance so future tests follow the same layering rules.

## Out of Scope

- Do not change product behavior while refactoring tests.
- Do not remove the production SQLite persistence implementation.
- Do not add a new real database integration suite unless the user explicitly asks for it; the immediate goal is to remove real database dependency from the default tests.
- Do not compensate by creating brittle giant mocks that reproduce the whole application. Prefer small fake modules with explicit behavior per test.
- Do not rewrite UI styling or product copy except where tests are currently overasserting implementation details.

## Acceptance Criteria

- `mix test` does not start `SymphonyElixir.Repo` against a real SQLite database.
- `mix test` does not create SQLite database files, run Ecto migrations, or require Exqlite connectivity.
- UI tests use fake persistence/runtime/Linear providers and assert UI-only outcomes:
  - rendered labels and controls;
  - form submission feedback;
  - navigation and tab state;
  - emitted calls to mocks.
- Business logic tests do not render LiveViews or call HTTP routes to test pure decisions.
- Domain modules have direct tests for:
  - workflow parsing/import detection;
  - workflow form conversion and validation;
  - settings save/no-op decision logic;
  - Linear state validation;
  - workspace source path decisions;
  - agent exit classification and retry decisions.
- Persistence-related behavior is covered through adapter contracts using mocks, not a real DB.
- Tests that genuinely require subprocesses, git commands, or network-like behavior are isolated behind fake command runners or marked outside the default unit/UI suite.
- Test names and file organization make it clear which layer is under test.
- The suite remains green after the refactor, and coverage does not drop below the current meaningful behavior coverage.

## Test Cases

- Run the default suite and assert no test starts `SymphonyElixir.Repo`.
- Run the default suite and assert no `*.sqlite`, `*.sqlite-wal`, or `*.sqlite-shm` files are created under test temp paths.
- Convert `auth_persistence_web_test` into:
  - UI/controller tests with mocked auth/persistence responses;
  - pure auth/persistence decision tests that do not touch Repo.
- Convert `web_fake_persistence_test` so it remains UI-only and asserts calls made to fake providers instead of serialized database effects.
- Convert workflow import/save tests so parser and draft merge behavior are tested directly in domain tests, while LiveView tests only assert import UI feedback and tab draft visibility.
- Convert orchestration/status tests so retry, exit classification, and snapshot rendering are tested with fake runtime state rather than database-backed runs.
- Remove or rewrite `test_database_isolation_test` and `test/support/database_isolation.exs` if their only purpose is managing real database state.
- Add a guard test or support assertion that fails when a default test starts Repo or configures a real database path.

## Implementation Notes

- Start by mapping test files to layers before editing. Do not mechanically rewrite all tests in place without knowing their ownership.
- Prefer narrow behavior modules where needed. If a LiveView handler contains business decisions that cannot be tested without rendering the page, extract the decision into a pure function or service module first.
- Keep `FakePersistence` intentionally small. It should expose the calls needed by UI and orchestration tests, not become a second persistence implementation.
- Replace "save and then query the database" assertions with "submit and assert fake provider received expected command" in UI tests, and direct domain tests for the serialized payload.
- For persistence adapter contracts, mock the repository API rather than using Ecto/Exqlite. If a contract cannot be tested without Ecto, mark that as a design smell and extract the logic above Repo first.
- Avoid snapshot-style HTML assertions. Assert stable labels, controls, toast states, and semantic messages.
- Keep existing command-runner and Linear fakes; extend them only where needed to remove real external behavior from default tests.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`
- A repository search showing no default test calls real database setup helpers:
  - no default test starts `SymphonyElixir.Repo`;
  - no default test imports `DatabaseIsolation`;
  - no default test configures an Exqlite database path.
- `git diff --check`

## Completion Deviations

Delivered as the first default-suite boundary cleanup rather than a full file-by-file rewrite of every existing test. The default `mix test` suite no longer loads `test/support/database_isolation.exs`, reads the configured Repo database path, or keeps tests for a temporary SQLite database safety helper. The removed helper was superseded by a direct boundary test that asserts:

- `SymphonyElixir.Repo` is not running;
- `:start_repo` is false;
- the configured persistence provider is `FakePersistence`;
- no Symphony-named SQLite/DB files are created under the system temp root.

Existing UI/domain tests were already largely using `FakePersistence` and explicit fake clients from prior plans, so this plan focused on removing the remaining real-database test harness path and documenting the current rule. No production SQLite behavior was changed.

Verified with:

- `mise exec -- mix format`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `mise exec -- mix test`

## Dependencies

- Completed plan 025 for earlier database isolation work, which this plan supersedes for default tests.
- Completed plan 026 for persistence boundary and mocked tests.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 093 for save-only-when-dirty behavior.
- Completed plan 098 for current Settings import behavior and draft preservation.

## Handoff Notes

The important outcome is test ownership, not simply deleting slow tests. If a test currently proves real behavior through the database, preserve that behavior by moving the assertion to the correct layer with a mock boundary. Default tests should be fast, deterministic, and explain failures by layer: UI failure means UI broke; domain failure means business logic broke; adapter failure means boundary contract broke.
