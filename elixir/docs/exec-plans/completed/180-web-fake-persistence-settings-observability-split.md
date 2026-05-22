# 180 Web Fake Persistence Settings Observability Split

## Goal

Move settings and observability page tests out of the legacy `web_fake_persistence_test.exs` smoke harness.

## Status

Completed.

## Background

Plan 170 added focused web tests but left `web_fake_persistence_test.exs` intact as a broad smoke harness. The file is still about 1,900 lines and mixes settings, runs, issue detail, events, workers, imports, and worker API behavior.

The next useful atomic split is to move two high-churn areas:

- settings pages and import/history behavior;
- persisted observability pages such as runs, run detail, issue detail, and events.

Both now have presenter/helpers and can be tested separately while preserving one small fake-persistence smoke path.

## Scope

- Move settings workflow/agents/import/history tests into settings-owned LiveView test files.
- Move runs/run detail/issues/events tests into observability-owned LiveView test files.
- Keep fake persistence setup shared through explicit test support.
- Keep a small smoke test proving the fake persistence bootstraps the web stack.

## Out of Scope

- Changing routes or page behavior.
- Removing fake persistence.
- Adding browser-only tests.
- Splitting worker API tests in this plan.

## Acceptance Criteria

- Settings tests can run without observability cases.
- Observability page tests can run without settings cases.
- `web_fake_persistence_test.exs` is materially smaller and only owns cross-cutting smoke coverage.
- Assertions are preserved or moved with equivalent coverage.

## Verification

- `mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mix test test/symphony_elixir_web/live/settings*_test.exs`
- `mix test test/symphony_elixir_web/live/observability*_test.exs`
- `rg -n "workflow page|agent settings|settings import|run detail|events page|issue detail|version histories" test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir_web`
- `mix exec_plans.check`

