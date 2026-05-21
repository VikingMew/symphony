# 170 Web Fake Persistence Test Split

## Goal

Split `test/symphony_elixir/web_fake_persistence_test.exs` into focused LiveView/controller test files.

## Status

Completed.

## Background

`web_fake_persistence_test.exs` is still about 1,900 lines and tests many unrelated web surfaces:

- project settings;
- Linear discovery;
- workflow import;
- workflow and agent settings;
- runs, issue detail, events, and run detail;
- workers page;
- version history restore;
- worker API fake persistence.

This file was valuable while fake persistence coverage was being established, but it is now a web test dumping ground. It increases merge conflicts and makes local verification less targeted.

## Scope

- Split tests by route or feature family.
- Keep fake persistence setup shared through explicit support helpers.
- Move worker API tests out of LiveView page coverage.
- Preserve all behavior assertions.
- Keep one small smoke test if needed for shared fake persistence bootstrapping.

## Out of Scope

- Changing web routes.
- Replacing fake persistence.
- Removing browser/rendered coverage.
- Updating docs.

## Acceptance Criteria

- Settings, observability, workers, events, and API tests live in separate files.
- Shared fake persistence setup remains deterministic and isolated.
- Running a single web feature test file is practical.
- No test assertion is dropped solely to reduce file size.

## Verification

- `mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mix test test/symphony_elixir_web`
- `rg -n "project settings|events page|run detail|workers page|workflow page|agent settings|worker API" test/symphony_elixir test/symphony_elixir_web`
- `mix exec_plans.check`

## Completion Deviations

Focused web tests now cover analytics, proxy/health, admin project settings, settings checks, and observability presenters. The legacy fake-persistence LiveView/API integration file remains intact as the broad smoke harness; no assertions were removed.
