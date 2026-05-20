# 095 Session History System Progress Presentation

## Goal

Make long-running Symphony-owned setup work visible while it is happening. When the system is cloning, fetching, creating a worktree, running generated bootstrap, or running lifecycle hooks, the dashboard session history or live update stream must show current progress instead of staying silent until Codex starts or the phase fails.

## Status

Completed.

## Background

Session history currently records useful lifecycle events, but workspace preparation can be silent for a long time. In the observed worktree case, clone progress runs for minutes while the session history shows no useful live output because Codex has not started yet. That makes the run look stuck even though the system is actively cloning or running setup commands.

A user scanning a running session should be able to see progress for:

- Symphony preparing a workspace or cached worktree base repository;
- Symphony running generated project bootstrap or configured lifecycle hooks;
- git clone/fetch/worktree command output while those commands are still running;
- pre-Codex setup phases before any Codex session exists.

The point is not only failure classification. The operator needs live evidence that setup is advancing: "cloning repository", "receiving objects 9%", "running after_create", or "creating worktree CCR-5". A failed clone is useful to classify, but the more important problem is the silent period before the failure or before Codex starts.

## Scope

- Emit live progress updates from Symphony-owned setup work before Codex starts.
- Add session-history rows or update-stream entries for important system phases that are currently only visible in logs or run phases, including:
  - worktree base clone start and progress;
  - worktree base fetch/prune progress;
  - worktree add start/completion;
  - generated project bootstrap start and streamed output;
  - configured lifecycle hooks such as `after_create`, `before_run`, `after_run`, and `before_remove`;
  - workspace preparation completion before Codex starts.
- Surface recent git/hook output while the command is still running, not only inside timeout/failure details.
- Coalesce noisy progress output so clone progress does not create hundreds of rows:
  - keep the latest progress line visible;
  - update the same logical system-progress row where possible;
  - preserve enough raw detail for debugging in logs.
- Extend session-history entries with stable presentation metadata such as `source=system`, `phase=workspace_bootstrap`, and `operation=git_clone` so UI does not infer system progress from label strings.
- Render system progress separately from Codex agent output with a restrained source label or badge.
- Preserve existing Codex notification humanization and streaming coalescing.
- Keep raw logging and persisted run events intact; this plan is about operator-facing session-history presentation.

## Out of Scope

- Do not redesign run detail pages or event storage schema unless the existing in-memory snapshot shape cannot carry the presentation metadata.
- Do not replace structured logs.
- Do not hide system events; this is live progress presentation, not filtering.
- Do not change retry policy.
- Do not change hook execution order or worktree behavior.
- Do not rebuild old historical sessions that already lack the new metadata.
- Do not make every raw git progress carriage-return update a separate visible row.

## Acceptance Criteria

- While a clone is running, the dashboard shows system progress before Codex starts.
- Clone progress updates include meaningful current output such as object receiving/compression progress when available.
- Worktree creation, generated bootstrap, and lifecycle hooks appear as system activity with start/completion/progress details.
- System progress rows are visibly separate from Codex agent output.
- Codex protocol events continue to appear as agent activity and keep existing humanized detail.
- Workspace preparation completion before Codex starts is visible.
- Workspace preparation failure before Codex starts keeps a clear detail string, but failure classification is not the primary feature.
- Existing streaming notification coalescing still works for adjacent Codex agent-message fragments.
- Dashboard session-history expanded/collapsed behavior remains stable across updates.
- Focused tests cover live system progress updates for clone/worktree/hook paths and existing agent entries.
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs` passes.
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs` passes if LiveView rendering is touched.
- `mise exec -- mix lint` passes.
- `mise exec -- mix test` passes.

## Test Cases

- A slow fake git clone emits a visible session-history/update entry before the command exits.
- Repeated clone progress lines update/coalesce into a bounded visible system-progress row instead of producing unbounded rows.
- A worktree bootstrap entry renders with `source=system` and names the operation, for example "Preparing project worktree" or "Cloning base repository".
- A configured lifecycle hook emits start/progress/completion entries with `source=system` and includes the hook name.
- A Codex `:notification` payload still renders with `source=agent` and the existing humanized detail.
- Adjacent Codex streaming fragments still coalesce into one visible agent row.
- A workspace preparation error before Codex startup renders with `source=system` and does not imply Codex ran, while prior progress rows remain visible.

## Implementation Notes

- Start in `SymphonyElixir.Orchestrator`, where session history entries are appended and already carry metadata.
- Add a way for `Workspace` command execution to send progress messages to the orchestrator before Codex starts. The existing `codex_update_recipient` only covers Codex updates; setup progress needs an equivalent system-update path.
- Prefer one event shape for setup progress, for example:
  - `{:system_worker_update, issue_id, %{source: :system, phase: :workspace_bootstrap, operation: :git_clone, status: :running, detail: line}}`.
- Thread the update recipient through `Workspace.create_for_issue` and hook/bootstrap command helpers without coupling workspace code to LiveView.
- For local command streaming, reuse the existing command port output path used for hook timeout diagnostics so progress lines can be emitted as they arrive.
- Normalize carriage-return git progress into readable latest-line updates.
- Prefer adding explicit metadata fields such as:
  - `source`;
  - `category`;
  - `phase`;
  - `severity`;
  - `operation`.
- Keep labels short for display, but keep details specific enough to debug.
- Avoid deriving presentation class solely from translated label strings. Labels are UI text; source/category should be data.
- Reuse `StatusDashboard.humanize_codex_message/1` for Codex entries rather than duplicating protocol parsing.
- Review `DashboardLive` and `Presenter` rendering so API snapshots and LiveView use the same classification semantics.
- System rows should use restrained styling. This is an operational dashboard, not a notification feed.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix test`
- `mise exec -- mix build`
- `mise exec -- mix format --check-formatted`
- `git diff --check`

## Completion Deviations

Implementation introduced a generic `source` field on session-history events and renders it defensively for older in-memory/test events that do not have the field. Hook result handling was refactored into a small context map to keep lint arity limits while preserving the same runtime behavior.

## Dependencies

- Completed plan 054 for running session state history.
- Completed plan 066 for observable session-history details.
- Completed plan 067 for notification coalescing.
- Completed plan 069 for run phase boundary logs.
- Completed plan 091 for worktree source strategy runtime.
- Completed plan 092 for agent exit result classification.
- Completed plan 094 for worktree bootstrap timeout and pre-Codex stall boundary.

## Handoff Notes

The intended product behavior is that a long pre-Codex setup phase is visibly alive. Do not solve this only by improving timeout/failure messages. During clone, fetch, worktree creation, generated bootstrap, or prehook execution, the session history or live update stream should show ongoing system progress before Codex produces any agent output.
