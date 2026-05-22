# 177 Core Test Prompt Agent Split

## Goal

Move prompt-builder and agent-runner tests out of `core_test.exs` into domain-owned files.

## Status

Completed.

## Background

Plan 168 marked the broad core-test split completed because focused tests already existed, but `test/symphony_elixir/core_test.exs` still remains around 2,700 lines.

The most obvious mechanical split is the prompt/agent section:

- prompt builder rendering and strict variable behavior;
- setup-required prompt fallback;
- profile prompt templates;
- agent runner successful run behavior;
- Codex update forwarding;
- Ready to In Progress transition behavior;
- follow-up turn behavior;
- agent max-turn stopping;
- app-server startup payload tests embedded near agent tests.

This section has clear ownership and can move without changing production behavior.

## Scope

- Move prompt builder tests to `prompt_builder_test.exs` or equivalent.
- Move agent runner tests to `agent_runner_test.exs` or equivalent.
- Keep only true cross-domain smoke tests in `core_test.exs`.
- Preserve helper setup and assertions exactly unless a helper extraction is required.

## Out of Scope

- Changing prompt rendering.
- Changing agent execution behavior.
- Removing integration coverage.
- Splitting every `core_test.exs` section in this plan.

## Acceptance Criteria

- Prompt-builder failures point to a prompt-builder test file.
- Agent-runner failures point to an agent-runner test file.
- `core_test.exs` loses the prompt/agent block and becomes materially smaller.
- All moved tests keep their original assertions.

## Verification

- `mix test test/symphony_elixir/prompt_builder_test.exs`
- `mix test test/symphony_elixir/agent_runner_test.exs`
- `mix test test/symphony_elixir/core_test.exs`
- `rg -n "prompt builder|agent runner|Ready to In Progress|max_turns|follow-up turn" test/symphony_elixir/core_test.exs test/symphony_elixir`
- `mix exec_plans.check`

