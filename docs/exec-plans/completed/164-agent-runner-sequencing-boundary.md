# 164 Agent Runner Sequencing Boundary

## Goal

Extract agent execution sequencing policy out of `SymphonyElixir.AgentRunner`.

## Status

Completed.

## Background

`AgentRunner` still owns workspace selection, implementation branch preparation, merge execution, Ready to In Progress transition, Codex turn loops, continuation checks, worker host selection, and phase event emission.

Some of that is side-effect orchestration, but several pieces are policy:

- when implementation start transition is required;
- whether a workflow transition is allowed;
- how follow-up turns continue or stop;
- how worker host selection is normalized;
- how failure summaries and phase payloads are shaped.

The module is still in the coverage ignore list with an exit slice that asks for extraction of exit classification and workspace/Codex sequencing. This plan turns that into a concrete implementation slice.

## Scope

- Extract pure execution policy helpers into a counted module.
- Keep actual workspace, Git, Linear, and Codex side effects in `AgentRunner`.
- Add focused tests for transition eligibility, continuation decisions, worker-host selection, and failure summary classification.
- Reduce the need for broad `core_test.exs` coverage of agent runner internals.

## Out of Scope

- Changing agent execution behavior.
- Rewriting the turn loop as a new process.
- Changing Linear mutation semantics.
- Changing merge executor behavior.

## Acceptance Criteria

- `AgentRunner` delegates transition and continuation decisions to a small policy module.
- Policy tests cover the behavior without launching Codex or mutating Linear.
- Existing agent runner integration tests still pass.
- Coverage ignore governance can point to the new counted policy module as progress toward removing the broad ignore.

## Verification

- `mix test test/symphony_elixir/agent_runner_test.exs`
- `mix test test/symphony_elixir/core_test.exs`
- Focused tests for the extracted policy module
- `rg -n "implementation_start_transition_required|workflow_transition_allowed|continue_with_issue|selected_worker_host|failure_summary" lib test`
- `mix exec_plans.check`

## Completion Deviations

Extracted deterministic AgentRunner policy helpers into `SymphonyElixir.AgentRunner.Policy` and added focused tests for implementation start transitions, continuation, worker host selection, and failure summaries.
