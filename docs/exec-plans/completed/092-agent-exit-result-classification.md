# 092 Agent Exit Result Classification

## Goal

Distinguish agent success, retryable failure, and terminal failure as explicit runtime outcomes instead of treating every non-normal task exit as an opaque crash.

Correct agent completion should not be logged or represented as retry. Failed agent execution should produce a concise, structured failure reason; retry should happen only for retryable failure classes. Non-retryable failures should stop that issue run and surface an actionable reason.

## Status

Implemented.

## Background

`AgentRunner.run/3` currently returns `:ok` for success but raises `RuntimeError` for any failure:

```elixir
raise RuntimeError, "Agent run failed for ... #{inspect(reason)}"
```

The orchestrator monitors the task and sees only the task `:DOWN` reason. This creates three problems:

- normal completion and continuation checks are described with retry-shaped language,
- all failures become task crashes, even when the failure is an expected domain result such as workspace bootstrap timeout,
- logs can explode with huge `inspect(reason)` payloads, for example Git clone progress in `recent_output`.

The observed failure is a project bootstrap timeout while cloning a repository. The relevant signal is:

- issue identifier,
- phase: `project_bootstrap` / `workspace_bootstrap`,
- timeout: `60000`,
- elapsed time,
- recent output summary.

The current log instead wraps that inside a `RuntimeError`, stacktrace, task reason, retry warning, and final task-finished line, duplicating large output and making it hard to see whether Symphony intentionally retried or simply crashed.

There is also a configuration ownership problem. The `60000` timeout currently comes from `hooks.timeout_ms`, surfaced in Settings / Workflow as `Hook timeout ms`. `project_bootstrap` uses the same timeout even though it is no longer conceptually a user hook. Project initialization should have its own Workflow-owned timeout, for example `workspace.initialize_timeout_ms`, shown in Settings / Workflow's Bootstrap area as `Initialize timeout ms`.

## Scope

- Introduce an explicit agent result contract between `AgentRunner` and `Orchestrator`.
- Stop using `raise RuntimeError` as the normal failure transport for expected agent run failures.
- Preserve real process crashes as crashes, but keep them visually distinct from domain failures.
- Classify agent outcomes at least into:
  - `:completed`,
  - `:completed_needs_continuation_check`,
  - `{:failed, retry_policy, reason}`,
  - `{:stopped, reason}` or equivalent terminal non-retry outcome.
- Rename continuation scheduling so correct completion is not logged as retry:
  - use wording like `scheduling active-state continuation check`,
  - avoid `Retrying ... delay_type=continuation` log text for successful runs.
- Add a failure classifier for expected runtime errors:
  - workspace/project bootstrap timeout,
  - workspace hook command failure,
  - workspace prepare failure,
  - Codex startup failure,
  - Codex approval / MCP elicitation hard-stop,
  - unsupported source strategy / invalid config.
- For each failure class, decide retry behavior:
  - retryable transient failures schedule retry with backoff,
  - non-retryable configuration or policy failures stop and require user action,
  - success never schedules a failure retry.
- Make timeout ownership and UI guidance explicit:
  - add an independent Workflow-owned initialize timeout field, for example `workspace.initialize_timeout_ms`,
  - render it in Settings / Workflow under Bootstrap as `Initialize timeout ms`,
  - use it for project source preparation and project setup commands,
  - keep `hooks.timeout_ms` for lifecycle hooks only,
  - in all initialization timeout failure messages, include where the operator can change the timeout.
- Sanitize failure logging:
  - log concise reason labels and bounded summaries,
  - cap `recent_output`,
  - normalize carriage-return progress output from Git clone/fetch,
  - avoid duplicating the same huge reason in `Agent task exited`, `Retrying`, and `Agent task finished`.
- Persist run finish status with the classified result:
  - success: `completed`,
  - retryable failure: `failed` plus retry scheduled event,
  - terminal stopped failure: `stopped` or `failed_non_retryable` depending on existing persistence vocabulary.
- Update dashboard/run events to show retryable vs stopped failure clearly.
- Update docs explaining the exit/result model.

## Out of Scope

- Do not change the Codex protocol or app-server behavior.
- Do not hide real unexpected process crashes.
- Do not remove retry/backoff entirely.
- Do not add a global retry limit unless the current retry model already supports it and this falls out naturally.
- Do not solve slow Git network performance in this task; only classify and report the timeout correctly.
- Do not add a broad timeout redesign across Codex, Git, HTTP, and worker snapshots.

## Acceptance Criteria

- [x] `AgentRunner.run/3` no longer raises `RuntimeError` for expected domain failures.
- [x] Orchestrator receives explicit agent outcomes, not only task crash reasons.
- [x] Correct agent completion logs as completed and schedules only a continuation check when needed; it is not logged as retry.
- [x] Retryable failures log one concise retry message with issue id, identifier, failure class, phase, attempt, delay, and bounded reason summary.
- [ ] Non-retryable failures do not schedule retry and clearly say what the operator should fix.
- [x] Workspace/project bootstrap timeout is classified as a domain failure, not by task crash default.
- [x] Bootstrap timeout messages say `Initialize timeout ms` controls the timeout and point to Settings / Workflow / Bootstrap.
- [x] Settings UI exposes `Initialize timeout ms` in the Bootstrap section.
- [x] `hooks.timeout_ms` no longer controls `project_bootstrap`.
- [x] Git progress output with carriage returns is compacted before logging and persistence.
- [x] `Agent task finished ... reason={%RuntimeError{...large output...}}` no longer appears for expected failures.
- [x] Real unexpected process crashes still show as crashes and schedule retry according to the crash policy.
- [x] Run history/events distinguish completed, retry scheduled, continuation scheduled, and crashed outcomes.
- [ ] Tests cover success, retryable domain failure, non-retryable domain failure, and unexpected crash.

## Test Cases

- Successful completion:
  - run an agent task that returns success,
  - assert no failure retry log/event is emitted,
  - assert any active-state follow-up uses continuation wording, not retry wording.
- Retryable workspace bootstrap timeout:
  - simulate `{:workspace_hook_timeout, "project_bootstrap", 60000, metadata}`,
  - assert the runner returns a classified failure instead of raising,
  - assert orchestrator schedules retry with a compact error summary,
  - assert the summary mentions the timeout setting location.
- Timeout settings discoverability:
  - open Settings / Workflow or the final chosen timeout location,
  - assert the Bootstrap section has `Initialize timeout ms`,
  - save a larger timeout and assert generated runtime config stores `workspace.initialize_timeout_ms`,
  - assert project bootstrap uses initialize timeout while `after_create` still uses `hooks.timeout_ms`.
- Non-retryable setup/config failure:
  - simulate missing project repository URL, unsupported source strategy, or invalid workflow setup,
  - assert orchestrator stops the issue run without retry,
  - assert the surfaced message points to Settings / Projects or Settings / Workflow as appropriate.
- Unexpected crash:
  - make the supervised task raise an unhandled exception outside the expected result path,
  - assert orchestrator logs it as a crash and keeps the existing crash retry behavior.
- Output compaction:
  - pass Git-style progress output containing repeated `\rReceiving objects...`,
  - assert the persisted/logged message is bounded and readable.
- Regression:
  - existing retry backoff and dashboard retry state tests still pass for retryable failure.

## Implementation Notes

- Prefer a small result module or struct, for example `SymphonyElixir.AgentResult`, so the contract is not a loose tuple spread across modules.
- Candidate result shape:

```elixir
%AgentResult{
  status: :completed | :retryable_failed | :stopped | :crashed,
  class: :workspace_bootstrap_timeout | :workspace_prepare_failed | :codex_startup_failed | ...,
  retry?: boolean(),
  reason: term(),
  summary: String.t(),
  phase: String.t() | nil,
  metadata: map()
}
```

- `AgentRunner.run/3` can continue to return `:ok` for direct unit tests only if there is a compatibility wrapper, but the orchestrator path should use the structured result.
- Avoid sending huge terms through logs. Keep full raw details in bounded event metadata only when useful, and apply the same output compaction before persistence.
- Existing `schedule_issue_retry/4` can remain for real retries, but continuation checks should get a separately named function and event type, such as `schedule_continuation_check/4`.
- The current timeout source is `Config.settings!().hooks.timeout_ms`, rendered as `Hook timeout ms`. Split this by adding a Workflow-owned `workspace.initialize_timeout_ms` or equivalent field. Use initialize timeout for `project_bootstrap`; keep `hooks.timeout_ms` for custom lifecycle hooks.
- Consider making failure classification pure and unit-testable:
  - `AgentResult.classify_error(reason)`,
  - `AgentResult.retry_policy(result)`,
  - `AgentResult.log_summary(result)`.
- Keep the distinction clear:
  - completed and still active: continuation check,
  - retryable failure: retry with backoff,
  - stopped/non-retryable failure: no retry,
  - unexpected crash: crash policy.

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/core_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

- The implementation uses a minimal `:ok | {:error, reason}` runner contract instead of adding a dedicated `AgentResult` struct. This keeps the runtime boundary explicit without a broader result refactor.
- Expected domain failures are currently retried through the existing retry/backoff policy. A future plan should split retryable and non-retryable domain classes, then stop configuration/policy failures without scheduling retry.
- Continuation checks now have separate log wording and event type, but still reuse the existing delayed scheduling storage internally.

## Dependencies

- Existing orchestrator retry/backoff model.
- Existing run phase events from Tasks 061, 064, 068, and 069.
- Existing workspace/project bootstrap timeout behavior from Tasks 064, 068, 090, and 091.
- Existing dashboard retry and session history UI.

## Handoff Notes

The important correction is not just shortening one log line. The runtime needs a typed boundary between agent execution and orchestration. Expected domain failures should be returned and classified; only unexpected bugs should look like task crashes. After this change, a slow project bootstrap clone should read as one concise classified failure with a clear retry or stop decision, not as a huge `RuntimeError` blob followed by ambiguous retry logs.
