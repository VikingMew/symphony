# 163 Run History Summary Boundary

## Goal

Separate run timeline row presentation from run execution summary derivation.

## Status

Completed.

## Background

`SymphonyElixir.RunHistory` now owns both detailed session-history rows and higher-level run summary extraction. These are related but not the same contract:

- timeline rows preserve ordered evidence for audit/debugging;
- summary derivation chooses final messages, actions, tools, commands, blockers, Linear updates, and evidence quality.

Keeping both in one module creates another broad presenter. It also makes it easier for timeline coalescing changes to accidentally alter the summary shown on run detail pages.

## Scope

- Keep timeline event normalization in `RunHistory`.
- Extract deterministic summary derivation into `SymphonyElixir.RunSummary` or a similarly named module.
- Define the summary data shape explicitly.
- Keep low-signal and streaming coalescing semantics covered separately from summary grouping.
- Preserve run detail page output unless tests document an intentional wording change.

## Out of Scope

- Adding a database table for summaries.
- Calling an LLM to summarize runs.
- Removing raw session history.
- Changing persisted event payloads.

## Acceptance Criteria

- Timeline row tests and summary tests are separate.
- `RunHistory` no longer contains final-message/action/tool/command/blocker aggregation logic.
- Run detail rendering consumes a named summary boundary.
- Low-signal legacy event behavior remains deterministic.

## Verification

- `mix test test/symphony_elixir/run_history_test.exs`
- Focused tests for the new run summary module
- `mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `rg -n "final_agent_message|tool_summaries|command_summaries|linear_updates|evidence_quality|blockers" lib test`
- `mix exec_plans.check`

## Completion Deviations

Added `SymphonyElixir.RunSummary` as the summary boundary and kept `RunHistory.summarize/2` as a compatibility facade for existing callers.
