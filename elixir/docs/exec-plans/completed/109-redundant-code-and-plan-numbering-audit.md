# 109 Redundant Code and Plan Numbering Audit

## Goal

Record the follow-up audit findings for redundant code and exec-plan numbering drift, then define a cleanup plan that can be implemented without changing runtime behavior.

## Status

Completed.

## Background

This audit reread the current working tree after plans 104-108 appeared in `docs/exec-plans/active/`. The worktree already contains uncommitted changes outside this audit, including new `RunHistory` and `RunLifecycle` modules plus changes to orchestrator, persistence, admin LiveView, docs, and workflow package files. Those changes are treated as current project context, not reverted or modified here.

The audit found recurring helper implementations and presentation logic that now appear in multiple modules. Some repetition is harmless, but several helpers encode security or runtime semantics and should become shared boundaries before more plans add parallel implementations.

## Findings

### P1: Shell escaping is duplicated across runtime boundaries

Evidence:

- `lib/symphony_elixir/codex/app_server.ex` defines `shell_escape/1`.
- `lib/symphony_elixir/config/schema.ex` defines `shell_escape/1`.
- `lib/symphony_elixir/ssh.ex` defines `shell_escape/1`.
- `lib/symphony_elixir/runtime_proxy.ex` defines `shell_escape/1`.
- `lib/symphony_elixir/workspace.ex` defines `shell_escape/1`.

Impact:

Shell escaping is security-sensitive. Five private copies make it easy for one boundary to drift when command construction changes. These modules also compose commands across local shell, remote SSH shell, generated bootstrap commands, proxy exports, and Codex launch scripts, so inconsistent escaping could become a real command-injection or quoting bug.

Plan:

- Introduce a small shared shell utility module, for example `SymphonyElixir.Shell`.
- Move single-quote POSIX escaping there with focused tests for quotes, whitespace, empty strings, paths, and command fragments.
- Migrate call sites gradually, preserving generated command strings.
- Keep any truly context-specific escaping named explicitly if it differs from POSIX shell escaping.

Acceptance criteria:

- Runtime modules call one shared shell escaping helper for POSIX shell command construction.
- Tests prove generated commands remain byte-for-byte compatible where compatibility matters.

### P1: Sensitive output redaction is duplicated and inconsistent

Evidence:

- `lib/symphony_elixir/git.ex` has `sanitize_output/1` with authorization/token/secret regexes.
- `lib/symphony_elixir/workspace.ex` has `sanitize_hook_output_for_log/2` with similar regexes plus output bounding.
- `lib/symphony_elixir/codex/app_server.ex` has `sanitize_startup_output/1` with env-name replacement and regex redaction.
- `lib/symphony_elixir/linear/client.ex`, `linear/diagnostics.ex`, and `linear/workflow_bootstrap.ex` each sanitize API/token-shaped error text.
- `lib/symphony_elixir/status_dashboard.ex` separately strips ANSI/control bytes.

Impact:

Redaction is a security boundary, but each caller has a slightly different regex and byte-bounding behavior. A new credential shape or output encoding could be fixed in one place and remain exposed in another.

Plan:

- Add a shared redaction/sanitization module, for example `SymphonyElixir.Redaction`.
- Provide separate functions for:
  - credential redaction;
  - ANSI/control-byte cleanup;
  - byte-bounded log output;
  - URI userinfo redaction if it remains proxy-specific.
- Port git/workspace/Linear/Codex/dashboard callers to the shared module.
- Add tests with representative Authorization headers, API key strings, token fields, proxy URLs, ANSI output, and long output.

Acceptance criteria:

- Credential-shaped output is sanitized through one shared implementation.
- Existing log/detail output remains bounded and readable.

### P1: Session history presentation now has parallel live and historical paths

Evidence:

- `lib/symphony_elixir/orchestrator.ex` builds live `session_history` events and sanitizes metadata.
- `lib/symphony_elixir_web/presenter.ex` serializes live session history into API payloads.
- `lib/symphony_elixir/status_dashboard.ex` humanizes Codex events and payloads.
- `lib/symphony_elixir/run_history.ex` independently maps persisted events into historical session history rows, including labels, details, severity, source, metadata bounding, and map key lookup.

Impact:

Plan 103 and new run history work are moving persisted history toward the same product surface as live session history. If live and historical presentation logic stay separate, operators can see different labels/severity/detail for the same underlying event depending on whether a run is active or historical.

Plan:

- Extract a shared session-history presentation boundary, for example `SymphonyElixir.SessionHistory`.
- Keep event ingestion/writing separate from presentation.
- Reuse existing `StatusDashboard.humanize_codex_message/1` or move the reusable humanization functions behind a public presentation module.
- Make both live dashboard/API and historical run detail use the same normalized row shape.

Acceptance criteria:

- A persisted event and equivalent live event render with the same label/detail/severity/source rules.
- API payload shape remains stable.

### P2: State normalization and blank checks are scattered

Evidence:

- State normalization appears in `Config.Schema.normalize_issue_state/1`, `Orchestrator.normalize_issue_state/1`, `AgentRunner.normalize_issue_state/1`, `Codex.DynamicTool.normalize_state/1`, `MergeExecutor.normalize_state/1`, `Linear.Discovery.normalize_state/1`, `Linear.WorkflowBootstrap.normalize_state/1`, and `Linear.WorkflowStateValidator.normalize_state_name/1`.
- `blank?/1` variants appear in `Config`, `Codex.AppServer`, `Workspace`, `Linear.Discovery`, `Linear.Diagnostics`, `AdminLive`, and `RunHistory`.

Impact:

Most copies currently trim/downcase or test empty strings, but small semantic differences already exist: some `blank?/1` functions treat non-binaries as blank, others stringify values. State comparison is central to Linear workflow routing and allowed transitions, so duplication increases the risk of one module accepting a state another rejects.

Plan:

- Add a shared lightweight string/state utility, for example `SymphonyElixir.Text` or `SymphonyElixir.StateName`.
- Use explicit functions:
  - `blank_string?/1` for only binary/nil semantics;
  - `present_string?/1`;
  - `normalize_state_name/1`.
- Migrate workflow/state modules first; leave UI-specific `blank_as_nil` helpers only when they encode form semantics.

Acceptance criteria:

- Workflow routing, diagnostics, merge, dynamic tool, and agent runner compare state names through the same helper.
- Tests cover nil, non-binary, whitespace, and mixed-case states.

### P2: Generic map access helpers are reimplemented in event presentation code

Evidence:

- `StatusDashboard` defines `map_value/2` and `map_path/2`.
- `Orchestrator` defines similar `map_value/2` and `map_path/2`.
- `RunHistory` defines `value/2` and `payload_value/2`.
- Several modules manually call `Map.get(map, "key") || Map.get(map, :key)`.

Impact:

Codex and Linear payloads frequently mix string and atom keys. The duplicated helpers all solve the same problem but are private, so every new presentation or protocol module tends to grow another copy.

Plan:

- Add a shared `SymphonyElixir.MapAccess` or `SymphonyElixir.Payload` helper for atom/string key lookup and nested paths.
- Keep it small: `fetch_any/2`, `get_any/2`, and `get_path/2` are likely enough.
- Migrate presentation/protocol code when nearby changes are already touching those modules.

Acceptance criteria:

- New event/payload code does not need private atom/string map lookup helpers.
- Existing behavior with string-key and atom-key payloads remains covered.

### P2: Worker task and run terminal status mapping is duplicated

Evidence:

- `lib/symphony_elixir/persistence.ex` maps `"task.completed"`, `"task.failed"`, and `"task.cancelled"` to terminal task attrs.
- The same event types are mapped again to terminal run attrs.
- `RunLifecycle.finish_run/5` and `Persistence.finish_run/4` now both encode terminal run update behavior.

Impact:

Run/task lifecycle fixes are active work. Duplicated terminal mapping makes it easy for task and run status behavior to diverge, especially around `finished_at`, `failure_reason`, and any future `interrupted`/`stopped` status.

Plan:

- Extract terminal event-to-attrs mapping into one lifecycle module.
- Decide whether `RunLifecycle` should call `Persistence.finish_run/4` directly or remain a generic helper over a persistence module.
- Ensure task terminal transitions and run terminal transitions share the same timestamp where appropriate.
- Add tests for all terminal event types.

Acceptance criteria:

- `"task.completed"`, `"task.failed"`, and `"task.cancelled"` terminal mapping lives in one place.
- Run terminal updates have one public boundary.

### P2: Test workflow YAML generation duplicates product serialization concepts

Evidence:

- `test/support/test_support.exs` manually builds workflow YAML with `yaml_value/1`, `project_yaml/1`, `worker_yaml/2`, `hooks_yaml/5`, `server_yaml/2`, and profile document helpers.
- Product code already owns split package parsing/normalization in `Workflow` and structured workflow config in `WorkflowForm`/`Config.Schema`.

Impact:

The test factory is useful, but it is now a second YAML serializer with its own formatting and defaults. That can hide drift: tests may pass against factory output even when repo-local package import/export behavior differs.

Plan:

- Keep a test fixture builder, but have it produce maps and pass them through the same product serialization/import path wherever possible.
- Add a small canonical split-package fixture for tests that need raw YAML.
- Reduce custom YAML string generation to cases that explicitly test parser behavior.

Acceptance criteria:

- Most tests build workflow configs as maps or through product export helpers.
- Parser tests remain the only tests relying on hand-written malformed YAML.

### P3: Exec-plan numbering is mostly continuous, but index drift remains

Evidence:

- Files under `docs/exec-plans/active` and `completed` currently cover 001-108 except missing 043.
- Highest plan number is 108 before this plan; this plan records as 109.
- `docs/exec-plans/README.md` Active Plans already lists 103-108.
- `docs/exec-plans/README.md` Completed Plans still jumps from 073 to 087 and omits 074-086, even though those files exist.

Impact:

Plan numbering is the project history index. Missing 043 may be intentional, but the README omission for 074-086 is current drift and makes completed work harder to discover.

Plan:

- Update the exec-plan README completed index to include 074-086.
- Add an explicit note for missing 043 if it is intentionally absent.
- Add a lightweight check that compares active/completed plan files to README entries.

Acceptance criteria:

- README index matches plan files or documents intentional gaps.
- Future numbering drift can be caught locally.

## Scope

- Introduce shared helper boundaries for repeated, security-sensitive utilities.
- Consolidate session-history presentation logic.
- Consolidate terminal lifecycle status mapping.
- Simplify test workflow fixture generation.
- Fix or document exec-plan numbering/index drift.

## Out of Scope

- Changing runtime behavior as part of this audit.
- Refactoring the entire large-module problem; plan 105 owns large module boundary work.
- Implementing coverage governance; plan 106 owns coverage policy.
- Changing Codex env inheritance; plan 107 owns that boundary.

## Acceptance Criteria

- The identified redundant helpers have clear target modules and migration order.
- Security-sensitive helpers such as shell escaping and redaction are no longer copied across unrelated modules.
- Live and historical session history share presentation semantics.
- Exec-plan numbering/index drift is fixed or enforced with a check.

## Test Cases

- Shared shell escape tests cover quotes, spaces, empty strings, and paths.
- Shared redaction tests cover Authorization headers, token/API-key patterns, URI userinfo, ANSI/control bytes, and bounded output.
- Shared state-name tests cover nil, non-binary, whitespace, and mixed-case input.
- Session-history tests compare live-shaped and persisted-shaped events for matching display rows.
- Lifecycle tests prove task terminal events and run terminal updates use the same status/timestamp semantics.
- Exec-plan index check fails if README omits existing plan files.

## Implementation Notes

- Start with low-risk shared helpers: shell escaping and redaction.
- Avoid a catch-all "Utils" module. Use narrowly named modules with stable semantics.
- Move callers opportunistically and verify generated strings/payloads before and after.
- Keep private UI form helpers private if they encode LiveView form behavior, even if their names resemble generic helpers.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/*redaction*` if a new redaction test file is added.
- `mise exec -- mix test test/symphony_elixir/*shell*` if a new shell utility test file is added.
- `mise exec -- mix test test/symphony_elixir/run_history_test.exs`
- `mise exec -- mix test test/symphony_elixir/run_lifecycle_test.exs`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs`
- `mise exec -- mix lint`
- `mise exec -- mix build`
- `git diff --check`

## Completion Deviations

Implemented the low-risk shared boundaries from the audit: `SymphonyElixir.Shell`, `SymphonyElixir.Redaction`, `SymphonyElixir.StateName`, and `SymphonyElixir.Payload`. Shell escaping, credential/control-byte redaction, several state-name comparisons, run history payload lookup, and task/run terminal mappings now share named helpers. The broad test YAML factory cleanup remains a follow-up because changing that fixture layer would be higher risk than the runtime-safe utility extractions.

## Dependencies

- Plan 103 for run session event history query.
- Plan 105 for large module boundary refactor.
- Plan 106 for coverage ignore governance.
- Plan 108 for run finished-at persistence.

## Handoff Notes

Do not collapse these helpers into a generic utility bag. The value is in giving security-sensitive and protocol-sensitive behavior a single named owner: shell command construction, redaction, state-name normalization, payload lookup, session-history presentation, and run lifecycle mapping.
