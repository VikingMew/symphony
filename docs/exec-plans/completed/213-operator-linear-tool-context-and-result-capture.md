# 213 Operator Linear Tool Context And Result Capture

## Goal

Fix `nap` and `day_dreaming` failures where restricted Linear issue creation reports `Workflow profile is unavailable for this Codex session`, and make every Symphony-owned Linear tool call observable as a structured success or failure.

Because Symphony exposes the restricted Linear MCP/dynamic tools, their outcomes are part of the product runtime. A tool failure must not disappear into a truncated agent final answer, and a tool success must be captured with enough durable evidence to understand what the agent created or updated.

## Status

Completed.

## Background

`nap` and `day_dreaming` now start real operator Codex runs, but the agent can fail when it tries to create backlog issues:

```text
Workflow profile is unavailable for this Codex session.
```

The immediate root cause is profile context loss between the operator runner and the restricted dynamic tool executor.

The operator runner knows the intended profile:

- `nap` for `Take a nap`;
- `day_dreaming` for product discovery.

It also builds the prompt with that profile policy. However, the default `AppServer.run_turn/4` tool executor currently derives the tool profile from `Config.workflow_profile_for_state(issue.state)`. Operator runs use synthetic issue states such as `Nap` or `Day dreaming`, which are not Linear workflow states. That lookup returns `nil`, so `linear_issue_create` receives no `profile` and correctly rejects the call.

There is a second product problem. When `linear_issue_create` fails, the agent may still produce useful backlog issue drafts in its final answer. Today those drafts can be truncated inside debug payloads or buried in session history. Conversely, when issue creation succeeds, the created Linear issue identifiers and URLs should be captured as first-class run evidence. Since these tools are implemented inside Symphony, Symphony should capture both outcomes directly at the tool boundary.

## Scope

- Preserve explicit workflow profile context for Codex sessions:
  - issue-backed runs may keep deriving the profile from the Linear issue state;
  - operator runs must pass `profile: "nap"` or `profile: "day_dreaming"` into `AppServer.run_turn/4`;
  - default dynamic-tool execution should prefer an explicit `opts[:profile]` over deriving from `issue.state`.
- Ensure restricted tool policy receives the correct profile for operator runs:
  - `linear_issue_create` is allowed for `nap` and `day_dreaming`;
  - it remains denied for profiles that are not allowed.
- Add structured capture for every Symphony-owned Linear dynamic tool call:
  - tool name;
  - run id/session id/turn id when available;
  - profile;
  - issue identifier or operator kind;
  - normalized arguments with secret/sensitive fields scrubbed;
  - success/failure status;
  - normalized result on success;
  - normalized error reason on failure;
  - timestamps and duration when available.
- Persist successful `linear_issue_create` results:
  - created Linear issue id;
  - identifier;
  - title;
  - URL;
  - state name;
  - source run id/profile/operator kind.
- Persist failed `linear_issue_create` attempts:
  - failure class such as profile unavailable, not allowed, validation failure, Linear context lookup failure, GraphQL error, or payload too large;
  - the safe input summary;
  - whether the agent later provided draft issue text in its final answer.
- Capture `linear_task_read` and `linear_task_update` success/failure with the same event model, because they are also Symphony-owned restricted tools.
- Make captured tool outcomes visible in run detail and session history in a readable way:
  - successful issue creation should show the created issue link;
  - failed issue creation should show the actionable reason;
  - raw payload should remain available only behind a debug/details disclosure.
- Ensure full final agent messages are durably available for operator runs when tool creation fails, so draft issue lists are not lost to UI truncation.

## Out of Scope

- Changing the text of the `nap` or `day_dreaming` prompts.
- Automatically retrying failed Linear issue creation without explicit policy.
- Creating fallback issues from free-form final-answer drafts in this plan.
- Changing Linear project/backlog state selection semantics except where necessary to report failures clearly.
- Exposing unsanitized raw tool arguments or Linear tokens.
- Replacing existing Codex protocol event persistence.

## Acceptance Criteria

- A `nap` operator run calling `linear_issue_create` receives profile `nap` at the tool boundary.
- A `day_dreaming` operator run calling `linear_issue_create` receives profile `day_dreaming` at the tool boundary.
- `linear_issue_create` no longer fails with `Workflow profile is unavailable for this Codex session` for valid operator runs.
- Issue-backed runs still derive their profile from Linear workflow state when no explicit profile is passed.
- Profiles other than `nap` and `day_dreaming` still cannot use `linear_issue_create`.
- Every restricted Linear tool call records a structured success or failure event.
- Successful issue creation records created issue identifier and URL in run detail.
- Failed issue creation records a normalized error reason in run detail.
- Operator final answers are persisted without relying on truncated debug payloads.
- If issue creation fails but the agent writes draft issue content, the run detail preserves that final-answer text so the drafts can be recovered.
- Session history remains readable and does not flood operators with raw protocol noise.

## Test Cases

- Operator profile propagation test:
  - start a fake `nap` operator turn;
  - execute `linear_issue_create`;
  - assert the tool receives profile `nap`.
- Operator profile propagation test:
  - start a fake `day_dreaming` operator turn;
  - execute `linear_issue_create`;
  - assert the tool receives profile `day_dreaming`.
- Regression test:
  - issue-backed run without explicit profile still derives profile from `issue.state`.
- Policy test:
  - implementation/refinement profile attempts `linear_issue_create`;
  - assert it is denied with `issue_create_not_allowed`.
- Failure capture test:
  - omit explicit profile for a synthetic operator issue;
  - assert the captured tool event records `workflow_profile_unavailable`.
- Success capture test:
  - fake Linear issue creation returns id, identifier, title, URL, and state;
  - assert the result is persisted and visible through run detail data.
- Validation failure capture test:
  - call `linear_issue_create` with missing required fields;
  - assert safe normalized arguments and validation reason are persisted.
- GraphQL failure capture test:
  - fake Linear context lookup or mutation fails;
  - assert the normalized failure class and reason are persisted.
- Final-answer retention test:
  - simulate a failed issue creation followed by a long final answer containing issue drafts;
  - assert the full final answer is persisted outside the truncated debug payload.
- UI/run-detail test:
  - successful tool call renders a concise created-issue row with a link;
  - failed tool call renders the failure reason and safe input summary;
  - raw/debug payload remains collapsed.
- Event-volume test:
  - multiple tool failures in one run produce bounded, grouped, readable run detail output.

## Implementation Notes

- The profile-context fix should happen at the Codex session/tool boundary:
  - pass explicit `profile` from `AgentRunner.run_operator/…` to `AppServer.run_turn/4`;
  - in `AppServer.run_turn/4`, compute tool profile as `opts[:profile] || Config.workflow_profile_for_state(issue.state)`;
  - pass the resolved profile into `DynamicTool.execute/3`.
- Avoid teaching `Config.workflow_profile_for_state/1` about synthetic operator labels like `Nap`. Operator profile is not a Linear state; it should be explicit runtime context.
- Consider a small `LinearToolAudit` or similarly named module that normalizes tool call outcomes before persistence.
- Capture should be close to the tool executor, not inferred later from agent prose. The executor is the only place that reliably sees arguments, normalized result, and normalized failure reason.
- Store safe summaries, not secrets:
  - Linear tokens must never be stored;
  - large text fields should be bounded in event summaries;
  - full final answers can be stored as run/session artifacts if the existing persistence model supports bounded large text, otherwise store them with explicit truncation metadata and a follow-up plan.
- Use stable failure classes rather than only `inspect(reason)` so Dashboard/run detail can group common problems.
- The UI should answer two separate questions:
  - did the restricted tool succeed or fail?
  - if it failed, did the agent produce recoverable draft output anyway?
- Keep `linear_issue_create`'s profile allowlist strict. The fix is context propagation, not loosening policy.

## Verification

- `mise exec -- mix format lib/symphony_elixir/codex/linear_tool_audit.ex lib/symphony_elixir/codex/dynamic_tool.ex lib/symphony_elixir/codex/app_server.ex lib/symphony_elixir/agent_runner.ex lib/symphony_elixir/orchestrator.ex lib/symphony_elixir/run_history.ex lib/symphony_elixir/event_presenter.ex test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/codex/app_server_dynamic_tool_policy_test.exs test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/codex/app_server_dynamic_tool_policy_test.exs test/symphony_elixir/run_history_test.exs test/symphony_elixir/orchestrator_operator_tasks_test.exs`
  - Result: `32 tests, 0 failures`.
- `mise exec -- mix test test/symphony_elixir/mixed_key_access_governance_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/codex/app_server_dynamic_tool_policy_test.exs test/symphony_elixir/run_history_test.exs`
  - Result: `29 tests, 0 failures`.
- `mise exec -- mix test`
  - Result: `641 tests, 0 failures, 2 skipped`.
- Coverage of the core acceptance path:
  - `AppServer.run_turn/4` now prefers explicit operator profile context over state-derived profiles for tool execution.
  - Operator runner passes `profile`, `operator_kind`, and `run_id` through to the Codex dynamic-tool boundary.
  - `linear_issue_create` success and failure both persist `linear.tool_call` audit events with safe arguments, normalized result/error, run/session/turn context, profile, and operator kind.
  - Run-history presentation renders `linear.tool_call` success and failure as readable Linear-sourced events.

## Completion Deviations

- Browser verification was not run. The run-detail behavior was verified through `RunHistory` presentation tests and full LiveView/controller regression tests instead of an in-browser manual scenario.
- Operator final-answer retention continues to rely on the existing Codex update/event stream and session-history coalescing. This plan added durable tool-boundary success/failure capture so failed Linear tool calls no longer depend on final-answer prose for diagnosis.

## Dependencies

- Completed plan 186 for restricted Linear issue creation.
- Completed plan 188 for day dreaming issue-generation intent.
- Completed plan 211 for real operator task execution.
- Completed plan 141 for run detail agent execution summary.
- Completed plan 116 for readable run detail session history.
- Completed plan 198 for dynamic tool issue-create boundary.

## Handoff Notes

The observed failure is not a prompt failure and not a Linear permission problem by itself. The operator runner knows the correct profile, but the dynamic tool executor falls back to `issue.state`, and operator issues use synthetic states that are not workflow routing states.

Fix profile propagation first. Then make Linear tool calls auditable at the boundary so both success and failure are visible as Symphony runtime evidence, not reconstructed from truncated Codex payloads or final-answer prose.
