# 141 Run Detail Agent Execution Summary

## Goal

Make the run detail page readable as an operator-facing execution summary, not only as a detailed event timeline.

For a completed agent run, the page should quickly answer what the agent did, what it concluded, which important tools/commands it executed, what it changed or reported, and what difficulties or blockers it encountered.

## Status

Completed.

## Background

Recent run detail improvements made persisted Codex events visible and more informative. The page now shows meaningful rows such as tool calls, reasoning items, rate-limit updates, token updates, and agent message streaming.

That is better than empty `codex.update` rows, but it is still not the right default reading experience. The current `Session History` is too detailed for the normal question after a run completes:

- What did the agent do?
- What did it output?
- What commands or tools mattered?
- What did it discover?
- What problems or blockers did it hit?
- Did it modify files, push a branch, or comment on Linear?
- Why is the run marked `completed`, `failed`, or `stopped`?

Raw event timelines are useful for audit and debugging, but they should not be the primary summary. The run detail page needs a higher-level `Agent Summary` or `Execution Summary` above the detailed timeline.

## Scope

- Add a run-level execution summary section near the top of `/runs/:id`.
- Derive the summary from persisted run events, Codex updates, tool calls, command events, session history, and run metadata.
- Summarize the run into operator-readable groups:
  - outcome;
  - final agent message or final conclusion;
  - work performed;
  - key tools and commands;
  - files changed or repository actions when known;
  - Linear comments/updates when known;
  - errors, blockers, retries, stopped reasons, or incomplete handoff;
  - token/runtime context as secondary metadata.
- Keep detailed `Session History` available, but move it below the summary and consider default-collapsing low-level rows.
- Preserve raw payload access for audit/debugging.
- Add tests using realistic event fixtures for completed, failed, stopped, and low-signal runs.

## Out of Scope

- Do not remove the detailed session history table.
- Do not invent facts that are not present in persisted events.
- Do not require an LLM summarization call to render the page.
- Do not store unbounded Codex transcripts.
- Do not change agent execution behavior.
- Do not change Linear issue mutation behavior.

## Acceptance Criteria

- A completed run detail page shows an `Agent Summary` or `Execution Summary` before the detailed timeline.
- The summary includes the final agent message or a clear note that no final message was persisted.
- The summary lists important tools/commands without showing every start/completed event separately.
- The summary surfaces blockers/errors distinctly when present.
- The summary shows whether the run changed files, pushed, commented, or only inspected/reported when evidence exists.
- The detailed `Session History` remains available for audit.
- Low-level token/rate/reasoning lifecycle events do not dominate the default reading experience.
- Tests prove the summary is useful for completed, failed, and stopped runs.

## Test Cases

- Completed run with final agent message:
  - summary shows completed outcome;
  - summary includes final conclusion;
  - timeline remains available below.
- Run with tool calls and command executions:
  - summary groups key tools/commands by name;
  - repeated start/completed lifecycle events are not shown as separate summary bullets.
- Run with file changes:
  - summary shows changed file count or filenames when persisted evidence exists.
- Run with Linear comment/update:
  - summary shows Linear action evidence.
- Failed run:
  - summary shows failure reason and relevant error event.
- Stopped run:
  - summary shows stop reason or lack of final handoff.
- Low-signal legacy run:
  - summary states that detailed agent output was not persisted, instead of pretending there is a conclusion.

## Implementation Notes

Prefer a presenter boundary rather than adding complex grouping logic directly in the LiveView template.

Potential module:

```elixir
SymphonyElixir.RunSummary
```

Potential shape:

```elixir
%{
  outcome: :completed | :failed | :stopped | :running | :unknown,
  final_message: String.t() | nil,
  actions: [String.t()],
  tools: [%{name: String.t(), count: integer(), status: atom()}],
  commands: [%{command: String.t(), exit_code: integer() | nil, summary: String.t()}],
  files: [%{path: String.t(), action: String.t()}],
  linear_updates: [String.t()],
  blockers: [String.t()],
  evidence_quality: :complete | :partial | :low_signal
}
```

Use existing event humanization and payload scrub/bound helpers. Reuse `RunHistory` where useful, but keep the summary at a higher semantic level than timeline rows.

The summary should be deterministic and testable. Do not call an external LLM to summarize events. If a future plan adds optional LLM summaries, it should still build on this deterministic evidence model.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
  - `53 tests, 0 failures`
  - Covers deterministic summary extraction and rendered `/runs/:id` evidence showing `Agent Summary` above session history.
- `mise exec -- mix exec_plans.check`
  - Run after moving the plan to `completed/`.
- `git diff --check`
  - Run during final active-plan verification.

## Completion Deviations

None.

## Dependencies

- Completed plan 116 for readable run detail session history.
- Completed plan 118 for Codex history signal persistence.
- Completed plan 133 for events page signal/filtering.
- Existing `RunHistory` and run detail page.

## Handoff Notes

Treat `Session History` as detailed evidence, not the page's main answer. The run detail page should first explain the run in human terms, then let operators drill into the full event stream when needed.
