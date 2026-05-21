# 157 Input Required Blocked Sessions

## Goal

When Codex app-server reports that a run needs operator input, approval, or MCP elicitation, Symphony should pause the issue as a visible blocked session instead of treating it as a retryable failure.

Human-input blockers are not transient infrastructure failures. Retrying them repeatedly wastes attempts and hides the real operator action needed.

## Status

Completed.

## Background

Commit `3365695e85307ac50872418332cf3d2802cdda19` introduced the product behavior in upstream Symphony:

- treat Codex input-required and MCP elicitation events as blocked sessions;
- keep blocked issues claimed until Linear state/routing changes;
- add blocked counts and details to dashboard/API presenter payloads;
- render blocked sessions in the dashboard;
- add regression coverage for app-server and orchestrator blocked flows.

The current codebase already includes part of that behavior at the Codex app-server boundary. `SymphonyElixir.Codex.AppServer` recognizes MCP elicitation as input-required, including:

- `mcpServer/elicitation/request`;
- `mcp/elicitation/request`;
- `turn/input_required`;
- related `turn/*` input-required methods.

The missing behavior is downstream in orchestration and presentation. When app-server returns `{:turn_input_required, payload}` or `{:approval_required, payload}`, the orchestrator still treats it like a normal agent domain failure and schedules retry. That is wrong for operator-input blockers.

This plan should adopt the upstream commit's semantics but not blindly cherry-pick the old implementation. The local codebase has since been refactored into smaller boundaries such as Codex update parsing, orchestrator policy modules, and dashboard presenters. Implement the behavior in the current architecture.

## Scope

- Classify these outcomes as operator-input blockers:
  - `{:turn_input_required, payload}`;
  - `{:approval_required, payload}`;
  - app-server completion outcome `:input_required`;
  - app-server completion outcome `:needs_input`;
  - app-server completion outcome `:approval_required`;
  - MCP elicitation methods such as `mcpServer/elicitation/request` and `mcp/elicitation/request`.
- Stop scheduling normal retries for operator-input blockers.
- Move affected runs/issues into an explicit blocked state tracked by the orchestrator.
- Keep blocked issues claimed so they are not immediately redispatched.
- Surface blocked state in snapshots/presenter payloads:
  - blocked count;
  - issue identifier;
  - Linear state when known;
  - workspace path/worker host when known;
  - session id;
  - blocked time;
  - blocker reason;
  - last Codex event/message.
- Render blocked sessions in the dashboard as an operator-visible section.
- Release blocked claims when Linear state/routing changes make the issue no longer active/routable, or when terminal state cleanup applies.
- Persist enough run/event history to explain that the run is blocked, not failed from transient infrastructure.
- Add tests around app-server, orchestrator, presenter, and dashboard behavior.

## Out of Scope

- Do not implement an interactive UI to answer MCP elicitation.
- Do not auto-approve approvals or user input requests.
- Do not move Linear issues to `Done` for input-required blockers.
- Do not force a Linear state transition solely because a run is blocked.
- Do not remove normal retry behavior for transient crashes, network failures, workspace setup failures, or merge failures.
- Do not directly cherry-pick upstream commit `3365695` without adapting it to current local boundaries.

## Acceptance Criteria

- A Codex `mcpServer/elicitation/request` causes app-server to return input-required and the orchestrator to mark the issue blocked.
- A Codex `mcp/elicitation/request` follows the same blocked path.
- `{:turn_input_required, payload}` does not schedule a retry.
- `{:approval_required, payload}` does not schedule a retry.
- Blocked issues remain claimed and are not redispatched while still active/routable.
- Dashboard shows blocked count and blocked session details.
- Presenter/API payloads include blocked session details.
- Run detail/events make the blocked reason visible.
- Blocked issues are released when the Linear issue leaves active/routable workflow scope or reaches a terminal state.
- Existing retry behavior remains unchanged for non-input failures.

## Test Cases

- App-server MCP elicitation:
  - fake Codex emits `mcpServer/elicitation/request`;
  - app-server returns `{:error, {:turn_input_required, payload}}`.
- App-server alternate MCP elicitation:
  - fake Codex emits `mcp/elicitation/request`;
  - app-server returns input-required.
- Orchestrator input-required failure:
  - running agent exits with `{:turn_input_required, payload}`;
  - state moves entry out of `running`;
  - no retry is scheduled;
  - issue remains claimed;
  - blocked entry records reason and session metadata.
- Orchestrator approval-required failure:
  - same expectations for `{:approval_required, payload}`.
- Stall detection:
  - if the last Codex event indicates input required, stall handling blocks rather than retries.
- Redispatch prevention:
  - an active blocked issue is not selected for a new dispatch.
- Release on Linear state change:
  - blocked issue moves to terminal/non-active/non-routable state;
  - blocked entry and claim are released.
- Presenter/dashboard:
  - snapshot includes `blocked`;
  - dashboard renders blocked count and section.
- Non-input failure:
  - ordinary crash or workspace error still schedules retry as before.

## Implementation Notes

Use commit `3365695e85307ac50872418332cf3d2802cdda19` as a semantic reference, not as a direct patch source.

The current app-server input detection is already better than the upstream single-clause implementation because it supports multiple MCP elicitation method names. Preserve that behavior.

Implement the blocked-session transition near the current orchestrator retry/failure boundary. The local code currently handles agent domain failure around `handle_agent_domain_failure/5` and retry scheduling. That boundary should classify input-required failures before calling normal retry policy.

Prefer adding or extending a small policy/helper module if one already exists for orchestrator retry/stall decisions. Avoid growing `Orchestrator` with another large inline block if the local refactor has a clearer boundary.

Blocked entry shape should be small and presenter-friendly:

```elixir
%{
  issue_id: issue_id,
  identifier: issue_identifier,
  issue: issue_snapshot,
  worker_host: worker_host,
  workspace_path: workspace_path,
  session_id: session_id,
  error: "codex MCP elicitation requires operator input",
  blocked_at: DateTime.utc_now(),
  last_codex_message: last_codex_message,
  last_codex_event: last_codex_event,
  last_codex_timestamp: last_codex_timestamp
}
```

Blocked status should be observable but not terminal. It is a paused operational state owned by Symphony until the underlying Linear/routing situation changes or future UI support lets an operator resolve the prompt.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator/input_blocker_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir_web/dashboard_presenter_test.exs` (67 tests, 0 failures)
- Rendered dashboard/API evidence is covered by `extensions_test.exs`: `/api/v1/state` now exposes blocked counts/details, `/api/v1/:issue` returns `status: "blocked"`, and the dashboard LiveView renders the blocked section from a static snapshot.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

The delivered code focuses blocked-session behavior on the downstream orchestration and presentation gap identified in the plan. App-server MCP/input-required recognition already existed and remains covered by the existing app-server tests instead of duplicating those fixtures here.

## Dependencies

- Current Codex app-server input detection.
- Active plan 143 for orchestrator retry and stall boundary.
- Active plan 155 for dashboard LiveView presentation boundary.
- Upstream semantic reference: commit `3365695e85307ac50872418332cf3d2802cdda19`.

## Handoff Notes

The product behavior is the important part: input-required and MCP elicitation are operator blockers, not retryable failures. Implement that behavior in the current code structure rather than reverting to the older upstream patch shape.
