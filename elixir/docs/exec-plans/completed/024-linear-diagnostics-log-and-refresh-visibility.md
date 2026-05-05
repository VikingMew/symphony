# Task 024: Linear Diagnostics Log and Refresh Visibility

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: Task 021, Task 022, Task 023
**Created**: 2026-05-01

## Goal

Make Linear diagnostics explain what failed, which configuration was used, when probes last ran, and whether workflow edits refreshed the status shown on the Linear page.

Operators should be able to tell from the Web UI whether a Linear failure is caused by missing token, bad token, wrong project slug, missing states, assignee filtering, empty issue result, candidate fetch failure, or stale diagnostics after workflow changes.

## Background

Task 022 added a Linear diagnostics page and Task 023 made workflow source selection explicit. The page now shows high-level probe status, but it is still too hard to debug real setup failures:

- The operator cannot see a chronological probe log.
- The page does not clearly show when diagnostics last ran.
- The page does not show whether it has refreshed since the last workflow save/activation.
- The page does not explain which config values were used for each probe.
- The workflow page saves and activates workflow versions, but does not tell the user to refresh/re-run Linear diagnostics or link directly to the Linear page.
- Server logs do not emit enough structured context for Linear diagnostics failures.

This creates uncertainty: after editing `/workflows`, the operator cannot tell if `/diagnostics/linear` is showing old results or the new runtime workflow.

## Scope

- Add a diagnostics run timestamp and a stable run id to `SymphonyElixir.Linear.Diagnostics.run/1`.
- Add a chronological diagnostics log to the result, with one entry per decision/probe step.
- Render the diagnostics log on `/diagnostics/linear`.
- Render `Last run`, `Runtime source`, `Workflow version`, and `Project slug used` prominently on `/diagnostics/linear`.
- Add a `Refresh diagnostics` action result message that makes it obvious the page re-ran probes.
- After saving or activating a workflow on `/workflows`, show a clear message that runtime workflow was refreshed and Linear diagnostics should be re-run.
- Add a direct `/diagnostics/linear` link from the workflow save/activation success state.
- Add server-side `Logger` entries for Linear diagnostics failures with redacted/sanitized context.
- Keep logs safe: never write Linear tokens, Authorization headers, or full secret-bearing payloads.
- Add tests for stale/refresh visibility and log rendering.

## Out of Scope

- Persisting diagnostics logs to SQLite.
- Streaming live diagnostics over PubSub.
- Automatically re-running Linear diagnostics when `/workflows` changes.
- Adding a general logging dashboard.
- Mutating Linear issues.

## Acceptance Criteria

- [x] `/diagnostics/linear` shows `Last run` with a timestamp.
- [x] `/diagnostics/linear` shows a run id or sequence marker so repeated refreshes are visibly different.
- [x] `/diagnostics/linear` shows runtime source and workflow version/source detail used by the probes.
- [x] `/diagnostics/linear` shows the configured project slug and endpoint used for the run.
- [x] `/diagnostics/linear` has a chronological log/table of probe steps.
- [x] Each log entry includes step name, status, message, and sanitized metadata.
- [x] Refreshing diagnostics updates the timestamp/run marker and shows an explicit refresh result.
- [x] `/workflows` save success tells the user runtime workflow was refreshed and links to Linear diagnostics.
- [x] `/workflows` activation success tells the user runtime workflow was refreshed and links to Linear diagnostics.
- [x] Linear diagnostics failures are logged server-side with enough context to identify the failing probe.
- [x] Logs never include token values or Authorization headers.
- [x] Tests cover workflow save -> refresh message -> diagnostics link.
- [x] Tests cover diagnostics refresh marker changing.
- [x] Tests cover diagnostic log entries for missing token, bad slug, missing states, and candidate fetch failure.

## Test Cases

- Render Linear diagnostics with fake successful probes and assert `Last run`, runtime source, project slug, endpoint, and log entries are visible.
- Click `Refresh diagnostics` and assert the run marker or timestamp changes and a flash/message indicates diagnostics were re-run.
- Configure missing token and assert the page log includes a failed `api` step with safe text.
- Configure project slug miss and assert the page log includes a failed `project` step with the slug and no token.
- Configure missing workflow states and assert the page log lists missing active/terminal states.
- Configure candidate fetch failure and assert the page log identifies candidate fetch as the failing step.
- Save a workflow in database mode and assert `/workflows` shows a success message linking to `/diagnostics/linear`.
- Activate a workflow version and assert `/workflows` shows the same diagnostics guidance.
- Capture logs during diagnostics failure and assert sanitized context is present while secret values are absent.

## Implementation Notes

- Extend diagnostics result shape with fields such as:
  - `run_id`
  - `ran_at`
  - `runtime_source`
  - `config`
  - `probes`
  - `issues`
  - `log`
- Keep log entries structured maps:
  - `step`
  - `status`
  - `message`
  - `metadata`
- Metadata should be explicit and redacted:
  - endpoint
  - project slug
  - active states
  - terminal states
  - candidate issue count
  - runtime source
  - workflow version id
- Prefer `Logger.warning/1` for failed probes and `Logger.info/1` for successful diagnostic runs.
- Use a monotonic unique integer or UUID-like value for `run_id`; do not use secrets or request payloads.
- Keep the Web UI compact. A simple `Diagnostics Log` section with a table is enough.
- The workflow page does not need automatic cross-page refresh. It only needs to make the operator action explicit: "Runtime workflow refreshed. Re-run Linear diagnostics."

## Verification

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix lint`
- `mise exec -- mix test test/symphony_elixir/linear_diagnostics_test.exs`
- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix test`
- Manual check: edit `/workflows`, save, open `/diagnostics/linear`, refresh diagnostics, confirm run timestamp and log reflect the edited project slug.

## Completion Deviations

- The diagnostics refresh is manual-only. Workflow save/activation refreshes the runtime workflow cache and links the operator to Linear diagnostics, but it does not push an automatic cross-page diagnostics rerun.
- Server logs are emitted for runtime source resolution and warning/error diagnostics steps. Successful individual probes are visible in the Web UI diagnostics log but are not all written to server logs to avoid noisy logs.
- Existing tests that create persisted projects now use a timestamp-based suffix to avoid collisions with prior local SQLite test runs.

## Dependencies

- Shared navigator from Task 021.
- Linear diagnostics page from Task 022.
- Runtime workflow source consistency from Task 023.

## Handoff Notes

- Final diagnostics log entry schema is `%{step: String.t(), status: :ok | :warning | :error | :skipped, message: String.t(), metadata: map()}`.
- Workflow save success text: `Workflow saved. Runtime workflow refreshed. Re-run Linear diagnostics.`
- Workflow activation success text: `Workflow activated. Runtime workflow refreshed. Re-run Linear diagnostics.`
- Server logs use `linear_diagnostics step=<step> status=<status> message=<message> metadata=<safe metadata>` and redact token-like reason text.
- Diagnostics refresh is manual-only from `/diagnostics/linear`.
