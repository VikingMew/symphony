# 178 Workspace Config Test Domain Split

## Goal

Split `workspace_and_config_test.exs` into workspace, Linear client, dispatch policy, and config schema test files.

## Status

Completed.

## Background

`test/symphony_elixir/workspace_and_config_test.exs` is still nearly 2,000 lines and mixes unrelated domains:

- workspace clone/worktree/source preparation;
- hook execution and cleanup;
- Linear client pagination/proxy/error behavior;
- dispatch policy checks;
- config schema defaults and validation;
- sandbox policy resolution;
- path safety;
- remote workspace lifecycle.

Many of these domains now have extracted modules and focused tests. Keeping the old mixed file intact makes ownership ambiguous.

## Scope

- Move workspace lifecycle tests near workspace/source preparation/hook runner tests.
- Move Linear client tests near Linear client/normalizer tests.
- Move dispatch policy tests to orchestrator dispatch policy tests.
- Move config schema and runtime resolver tests to config-focused files.
- Keep only a small end-to-end workspace+config smoke path if needed.

## Out of Scope

- Changing workspace behavior.
- Changing config schema behavior.
- Removing integration coverage.
- Rewriting fixture builders.

## Acceptance Criteria

- A change in Linear client code does not require running a 2,000-line workspace/config mixed file as the primary target.
- Workspace source/hook/path-safety failures point to workspace-owned tests.
- Config schema failures point to config-owned tests.
- All assertions remain present after the move.

## Verification

- `mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mix test test/symphony_elixir/workspace`
- `mix test test/symphony_elixir/config`
- `mix test test/symphony_elixir/linear_client_test.exs`
- `rg -n "linear client|dispatch policy|schema|sandbox|workspace|worktree|hook" test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir`
- `mix exec_plans.check`

