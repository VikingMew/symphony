---
title: Workflow and Configuration Specification
genre: spec
domain: [spec, workflow-config]
status: current
language: en
owner: SymphonyElixir.Config
updated: 2026-08-28
---

# Workflow and Configuration Specification

## Refinement description limits

`profiles.refinement.description_limits` configures the non-blocking description-size signal.
When omitted, the character limit is `12000`, the logical-line limit is `400`, and
`label_overrides` is empty. Limits supplied at either level must be positive integers; invalid
values produce the standard typed `invalid_workflow_config` error.

Override keys are Linear label names. Matching trims and lowercases configured and issue labels.
When several overrides match, the effective character and line limits are independently the
largest matching values, including the defaults, so map iteration order cannot affect the result.
An override may supply one dimension; the other inherits the default.

## 5. Workflow Specification

### 5.1 Active Workflow Selection

Workflow source precedence:

1. Workflow policy is the immutable contract returned by
   `SymphonyElixir.Config.Schema.default_workflow_policy/0`.
2. Project settings and profiles come from the current workflow stored for the project.
3. Setup-required mode applies when no current workflow exists.

Loader behavior:

- If no active workflow exists, return a typed setup-required error and keep the service alive.
- The active workflow record is expected to be versioned and operator-visible.
- Implementations MAY support import/export package files, but package files are not startup
  authority unless an implementation explicitly imports them into the datastore.

### 5.2 Package Format

Portable workflow packages are implementation-defined. The current preferred package shape is split
YAML:

- `workflow.yml` for project settings plus a documented example of the code-owned state policy.
- `profiles.yml` for shared base prompt and profile-specific agent policy.

Design note:

- A package SHOULD be self-contained enough to recreate a project's settings and profiles after import.
- A package SHOULD NOT be edited in place as the runtime source of truth.
- Persisted `workflow` keys MUST be retained for raw import/export fidelity but MUST NOT affect
  runtime dispatch, transition validation, human-review classification, or profile routing.

The default package contains refinement and implementation profiles only. There is no backend merge
profile or merge success-state setting; GitHub/Linear automation owns the post-review completion.

`Blocked` is a human-review state and MUST NOT appear in `tracker.active_states`. Each executable
state MUST transition to `Blocked` with actor `symphony`;
`Blocked` may transition to `Ready`, `Needs Refinement Review`, or `Canceled` only with actor
`human`. Imports and current-workflow upgrades MUST preserve this non-dispatch contract.

Parsing rules:

- YAML files MUST decode to map/object roots; non-map YAML is an error.
- Base prompt fields are trimmed before use.
- Implementations MUST validate imported package data before replacing the current workflow.

Returned workflow object:

- `config`: normalized runtime config object.
- `prompt_template`: trimmed base prompt string.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`
- `project`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The workflow config object is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.
- A Symphony instance maintains one current workflow **per enabled project**. The workflow
  schema is the per-project policy; `tracker.project_slug`, the repository URL, and workspace
  hooks are overridable per project through the Project settings record, and persisted runs,
  issues, events, and worker tasks carry the originating `project_id`.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Refining`, `Ready`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Canceled`, `Cancelled`, `Duplicate`, `Done`

Default workflow policy:

- Executable routes: `Todo -> refinement`, `Refining -> refinement`, `Ready -> implementation`, and
  `In Progress -> implementation`.
- Human-review states: exactly `Needs Refinement Review`, `Ready to Merge`, and `Blocked`.
- Codex transitions: `Todo -> Refining`, `Refining -> Needs Refinement Review`,
  `Ready -> In Progress`, and `In Progress -> Ready to Merge`.
- Human change requests: `Needs Refinement Review -> Refining` and
  `Ready to Merge -> In Progress`.
- Symphony conflict reconciliation: `Ready to Merge -> Blocked` with `actor=symphony`.
- `Ready to Merge` MUST NOT appear in `tracker.active_states`.
- `Done` is the sole successful terminal state; `Canceled`, `Cancelled`, and `Duplicate` remain
  cancellation terminal states.

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `project.required_gates` (ordered list)

Worker execution snapshots resolve `project.required_gates` from the current PostgreSQL workflow
when a task is queued. Each entry requires a stable non-blank `name`, non-blank `command`, and
positive `timeout_ms`. Declaration order is execution and result order. The repository package
declares independent `check`, `unit`, and `dialyzer` script gates; live E2E is orchestrated by its separate workflow.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to an implementation-defined runtime base directory.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.

#### 5.3.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

### 5.4 Prompt Template Contract

The active workflow base prompt plus the selected profile prompt is the per-issue prompt template.
For refinement and implementation profiles, Symphony appends a non-configurable, highest-priority
container-validation safety contract after profile composition. It applies to every project even
when a profile replaces the base prompt: agents MUST NOT invoke container engines, daemons,
sockets, or image operations. A task that requires such validation MUST report blocker evidence
and use the persistent `blocking_decision` / `Blocked` path; allowed task-authored validation
remains mandatory. Static inspection of container source/configuration remains allowed.

When the `refinement` profile requests normalized state `Needs Refinement Review`, the same tool
request MUST contain the candidate description. Before any description or state write, Symphony
MUST apply the deterministic refinement quality gate defined by
`docs/codex-linear-task-refinement-workflow-design.md`. A failed gate writes one diagnostic comment
and returns its complete violation set as a typed tool error. If that comment write fails, the
Linear error remains explicit. The failure does not introduce a retry counter: an unfinished run
continues through the existing no-progress streak and persistent `BlockingDecision` path.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the active workflow prompt is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow parse/validation failures are configuration errors and SHOULD NOT silently fall back to a
  prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_active_workflow`
- `workflow_parse_error`
- `workflow_package_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Missing active workflow or workflow validation errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the current persisted workflow for the project.
2. Parse its raw workflow config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the implementation-defined runtime base
  directory.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- PostgreSQL is the durable authority, but normal runtime reads MUST resolve from one atomically
  replaced in-memory snapshot containing all enabled projects, default selection, source/version
  metadata, and setup/error state.
- Runtime reads MUST NOT query persistence, trigger refresh-on-read, or wait behind persistence
  refresh work. An absent cache owner MUST NOT cause caller-side database fallback.
- Successful workflow and project mutations MUST persist first and publish the complete replacement
  snapshot before reporting full success. Persistence success followed by publication failure MUST
  return a typed partial/refresh failure.
- The software MUST detect externally saved current-workflow changes in the background with at
  most one refresh in flight. Timer ticks during a stall MUST coalesce or skip.
- Background publication MUST use a generation guard so work started before a newer mutation cannot
  overwrite that mutation.
- On change, the software MUST re-read and re-apply workflow config and prompt/profile data without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Invalid or unavailable refreshes MUST NOT crash the service or expose a partial project set; keep
  the complete last-known-good snapshot, including setup-required, and emit a structured
  operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when REQUIRED by the selected tracker kind.
- `codex.command` is present and non-empty.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when `tracker.kind=linear`
- `tracker.project_slug`: string, REQUIRED when `tracker.kind=linear`; configured per project in
  the Project settings record (each enabled project names its own Linear project slug)
- `tracker.active_states`: list of strings, default `["Todo", "Ready", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Canceled", "Cancelled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null; overridable per project
- `hooks.before_run`: shell script or null; overridable per project
- `hooks.after_run`: shell script or null; overridable per project
- `hooks.before_remove`: shell script or null; overridable per project
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `codex.command`: shell command string, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`
