---
title: Workflow and Configuration Specification
genre: spec
domain: [spec, workflow-config]
status: current
language: en
owner: SymphonyElixir.Config
updated: 2026-09-23
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
2. Installation runtime/profile policy comes from the fixed PostgreSQL
   `app_settings["instance_workflow"]` value.
3. Tracker/repository settings come from the current PostgreSQL workflow slice for that project.
4. Setup-required mode applies when either the singleton or every enabled project workflow is absent.

Loader behavior:

- If either required durable scope is absent, return a typed setup-required error, keep the service
  alive, and do not treat a legacy full project row as an instance fallback.
- Each project has exactly one operator-visible current workflow slice. Runtime publication composes
  the singleton with every enabled project slice before parsing and atomically replaces the complete
  derived snapshot set.
- Reads without explicit project context select a configured, enabled `slug=default` workflow when
  present; otherwise they select the only enabled, loaded, non-placeholder project workflow when
  exactly one exists. If two or more enabled loaded workflows exist without a configured Default,
  return `:missing_project_context` instead of selecting by name or insertion order.
- The package under `docs/examples/` is example and import material, not a synchronization source:
  there is no package synchronization command and no drift contract between those files and the
  database. Manual workflow-table updates are outside the supported lifecycle; Settings / Import is
  the supported operator path.

### 5.2 Package Format

Portable workflow packages are implementation-defined. The current preferred package shape is split
YAML:

- `workflow.yml` for project settings plus a documented example of the code-owned state policy.
- `profiles.yml` for shared base prompt and profile-specific agent policy.

Design note:

- A package SHOULD be self-contained enough to recreate the instance policy and one project's settings.
- The package under `docs/examples/` is example and import material. Runtime code MUST read the
  project's PostgreSQL snapshot rather than files from the source checkout.
- `workflow` keys are portable example metadata only. Durable instance and project slices MUST NOT
  persist them; runtime dispatch, transition validation, human-review classification, and profile
  routing MUST use `Schema.default_workflow_policy/0`.
- `workflow.tool_policy.*.exposed_tools` is retained example-policy metadata, not a runtime
  dynamic-tool allowlist. The implementation completion surface is the code-owned `handoff`
  dynamic tool after `create_pull_request`.

The default package contains refinement and implementation profiles only. There is no backend merge
profile or merge success-state setting; GitHub/Linear automation owns the post-review completion.

`Blocked` is a human-review state and MUST NOT appear in `tracker.active_states`. Each executable
state MUST transition to `Blocked` with actor `symphony`;
`Blocked` may transition to `Ready`, `Needs Refinement Review`, or `Canceled` only with actor
`human`. Imports and current-workflow upgrades MUST preserve this non-dispatch contract.

Parsing rules:

- YAML files MUST decode to map/object roots; non-map YAML is an error.
- Base prompt fields are trimmed before use.
- Implementations MUST validate imported package data before atomically replacing its two durable scopes.
- Project persistence and project-slice export MUST reject out-of-scope fields with a typed error;
  they MUST NOT silently discard instance keys, profiles, base prompts, workflow policy, or secrets.

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

Unknown keys MAY be ignored by the general parser. Durable instance/project persistence and export
boundaries MUST reject keys outside their declared scope.

Note:

- The workflow config object is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.
- A Symphony instance maintains one runtime/profile singleton and one tracker/repository workflow
  slice per enabled project. Workspace roots, initialization/disk thresholds, lifecycle hooks,
  Codex policy, observability, analytics, server/worker policy, base prompt, and profiles have no
  per-project override. Persisted runs, issues, events, and worker tasks carry the originating
  `project_id`.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (runtime-only string)
  - MUST NOT be persisted in either durable workflow scope.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Todo`, `Ready`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Canceled`, `Cancelled`, `Duplicate`, `Done`

Default workflow policy:

- Executable routes: `Todo -> refinement`, `Refining -> refinement`, `Ready -> implementation`, and
  `In Progress -> implementation`. Only `Todo`, `Ready`, and `In Progress` are dispatch candidates;
  `Refining` is the started state used after refinement kickoff and on an explicit human return.
- Human-review states: exactly `Needs Refinement Review`, `Ready to Merge`, and `Blocked`.
- Codex transitions: `Todo -> Refining`, `Refining -> Needs Refinement Review`,
  `Ready -> In Progress`, and `In Progress -> Ready to Merge`.
- Human change requests: `Needs Refinement Review -> Refining` and
  `Ready to Merge -> In Progress`.
- Symphony conflict or PR-review finding delivery: `Ready to Merge -> Blocked` with
  `actor=symphony`.
- Human review-blocker recovery: `Blocked -> In Progress`.
- `Refining` and `Ready to Merge` MUST NOT appear in `tracker.active_states`.
- The independent `review` profile is not state-routed. It exposes only immutable context read and
  typed conclusion submission; deployment-level review capacity controls its durable queue.
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
declares independent `check`, `unit`, and `dialyzer` script gates plus PR description lint. Live
E2E is a credentialed manual suite run with `SYMPHONY_RUN_LIVE_E2E=1 mix test --only live_e2e` or
`scripts/e2e.sh`; it is not currently connected to CI.

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

- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_failure_retries` (non-negative integer)
  - Default: `3`
  - Maximum automatic retries after the first failed/crashed/stalled worker attempt.
  - Negative and non-integer values fail configuration validation.

#### 5.3.6 `codex` (object)

Fields:

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

`codex.model` and `codex.reasoning_effort` are Symphony-owned workflow selectors backed by one
code-owned Codex catalog snapshot. The app-server protocol field shape comes from
`codex-cli 0.156.0` generated schema evidence captured with
`codex app-server generate-json-schema --out tmp/codex-schema-sym-151-20260923`:

- `TurnStartParams.model` is nullable string and overrides the model for the current and
  subsequent turns.
- `TurnStartParams.effort` is nullable `ReasoningEffort` and overrides reasoning effort for the
  current and subsequent turns.
- `ReasoningEffort` is a non-empty string, not a closed JSON Schema enum.
- `model/list` returns `ModelListResponse`; each row exposes `id`, `model`, `displayName`,
  `defaultReasoningEffort`, and `supportedReasoningEfforts`.

The consumed contracts above are unchanged from the prior pin. The schema delta is confined to
protocol definitions Symphony does not consume: `ThreadAttachment*`, `ThreadRollback*`, optional
`disabledPluginIds`, the deprecated `personality` description, and model access program metadata.

The selector values come from `SymphonyElixir.Codex.ModelCatalog`, captured from the same target
Codex version by an initialized `codex app-server` `model/list` request with
`includeHidden=false` and `limit=100`. The snapshot rows are:

`Dockerfile:5` `ARG CODEX_VERSION` is the sole definition point for changing the Codex CLI
version. Any change to that argument MUST re-derive the `SymphonyElixir.Codex.ModelCatalog`
snapshot from the resulting Codex-capable image. The same pull request MUST update the snapshot's
`codex_version`, model rows, and supported reasoning efforts, and update the `codex-cli` version
and schema-generation command in the evidence above. Follow the Codex version-bump checklist in
`docs/compose.md` for the required capture and selector acceptance procedure.

| model | label | default effort | supported efforts |
| --- | --- | --- | --- |
| `gpt-6-astra` | GPT-6-Astra | `medium` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-6-sol` | GPT-6-Sol | `medium` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-6-luna` | GPT-6-Luna | `medium` | `low`, `medium`, `high`, `xhigh`, `max` |
| `gpt-5.6-sol` | GPT-5.6-Sol | `low` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-5.6-terra` | GPT-5.6-Terra | `medium` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-5.6-luna` | GPT-5.6-Luna | `medium` | `low`, `medium`, `high`, `xhigh`, `max` |
| `gpt-5.5` | GPT-5.5 | `medium` | `low`, `medium`, `high`, `xhigh` |

Validation rules:

- Omitted or blank `model` and `reasoning_effort` values normalize to absent config and MUST NOT
  send empty string overrides.
- Explicit `model` MUST exist in the catalog snapshot.
- Explicit `reasoning_effort` without explicit `model` MUST exist in the union of catalog efforts.
- Explicit `model` plus `reasoning_effort` MUST use an effort supported by that model row.
- Settings selectors and schema validation MUST read the same code-owned catalog source. Settings
  MUST NOT provide a free-text custom model input.
- `codex.command` MUST NOT set `model` or `model_reasoning_effort` through `-c` / `--config`, and
  MUST NOT use the synonymous `-m` / `--model` option. Validation errors MUST identify
  `codex.command` and direct the operator to the Settings / Runtime selectors. Other command
  options and other `-c` / `--config` keys remain valid.

Settings / Import converts the supported legacy command representation before it builds the
editable draft. Existing explicit selectors win; missing selectors are populated from the legacy
flags; the migrated flags are removed; and the staged diff exposes the command and selector
changes. This is an import-time conversion only. Launch, dispatch, and turn creation MUST NOT parse
model or effort from `codex.command`. The PostgreSQL data migration applies the same precedence to
persisted current workflows, updates legacy full workflow rows' `yaml_config` and `raw_workflow_md`
together, and updates the converged instance singleton or unresolved instance candidates when the
earlier scope migration has already moved Codex configuration there.

The checked-in `docs/examples/workflow.yml` package is import material, not runtime authority. Its
Codex block carries explicit `thread_sandbox: "danger-full-access"` and
`turn_sandbox_policy.type: "dangerFullAccess"` so new Settings / Import or cold-start imports do not
omit the worker non-bwrap policy. This does not change the implementation-defined behavior for a
runtime workflow that omits an explicit `turn_sandbox_policy`.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
  - This command remains the app-server process launch command and MUST NOT be parsed to infer
    model or reasoning effort.
  - `-c` / `--config` entries for `model` or `model_reasoning_effort`, and `-m` / `--model`, are
    invalid workflow configuration.
- `model` (optional string)
  - Default: absent.
  - When present, send as `turn/start.params.model` for subsequent Codex turns created from the
    parsed workflow snapshot.
  - When absent, do not send a structured model override.
- `reasoning_effort` (optional string)
  - Default: absent.
  - When present, send as `turn/start.params.effort` for subsequent Codex turns created from the
    parsed workflow snapshot.
  - When absent, do not send a structured effort override.
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
In a multi-project runtime, prompt rendering MUST use the workflow selected for the issue's project;
it MUST NOT perform an unscoped current-workflow lookup or fall back to another project's prompt.
For refinement and implementation profiles, Symphony appends a non-configurable, highest-priority
container-validation safety contract after profile composition. It applies to every project even
when a profile replaces the base prompt: agents MUST NOT invoke container engines, daemons,
sockets, or image operations. A task that requires such validation MUST report blocker evidence
and use the persistent `blocking_decision` / `Blocked` path; allowed task-authored validation
remains mandatory. Static inspection of container source/configuration remains allowed.

The default refinement and implementation profile prompts prohibit speculative safety, redundancy,
misuse-prevention, versioning, compatibility, fallback, and defensive-programming designs. Agents
MUST add those designs only when the issue text literally requires them and otherwise keep the
design or implementation minimal, consistent with the repository's no-defensive-programming and
pre-release governance.

The default refinement prompt MUST require a non-empty `Owning design docs` ATX section with the
fixed `Change classification` and `Design sync` enums. Behavior/architecture candidates MUST list
every `docs/*-design.md` owner and reference each owner in Scope and Acceptance criteria. A candidate
with no current owner MUST use `No owner: true` and include a non-empty `Owner registration plan:`
item in both sections. `non-behavior + not required` MUST include a non-empty `Reason:`.

The default implementation prompt MUST require review of that declaration against the actual diff.
Behavior changes under `lib/` and runtime-configuration semantic changes synchronize the owning L3
design and documentation-alignment row in the same change. Classification drift is corrected in the
Linear description or work record before delivery. A missing owner is disclosed in the PR body and
registered or merged into an existing owner in that PR; it is not an exemption.

The default implementation prompt MUST teach one worker completion action: after validation, commit,
push, and successful `create_pull_request`, Codex calls the `handoff` dynamic tool with final
comment/result/references and the returned PR URL/proof. Codex MUST NOT use `linear_task_update` to
request `Ready to Merge` as that completion action. Accepted handoff capture does not update Linear;
the worker runs required gates before restricted backend writeback.

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

1. Load the fixed installation singleton and the current workflow slice for the project.
2. Compose instance-owned fields with the project's tracker/repository fields and inject
   `Schema.default_workflow_policy/0`.
3. Parse the composed config map and apply built-in defaults for missing OPTIONAL fields.
4. Resolve the runtime tracker secret from its canonical environment contract.
5. Resolve `$VAR_NAME` indirection only for other config values that explicitly contain
   `$VAR_NAME`.
6. Coerce and validate typed values.

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
- Successful instance, workflow, and project mutations MUST persist first and publish the complete replacement
  snapshot before reporting full success. Persistence success followed by publication failure MUST
  return a typed partial/refresh failure.
- The software MUST detect externally saved current-workflow changes in the background with at
  most one refresh in flight. Timer ticks during a stall MUST coalesce or skip.
- Background publication MUST use a generation guard so work started before a newer mutation cannot
  overwrite that mutation.
- On change, the software MUST re-read the singleton and every enabled project slice, compose them,
  and re-apply workflow config and prompt/profile data without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, codex settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Worker assignment payloads MUST carry the parsed Codex config slice, including explicit
  `model`/`reasoning_effort` selectors. A later Settings save MUST NOT rewrite an already issued
  assignment payload.
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
- `codex.command` does not carry a model or reasoning-effort override.
- Configured `codex.model` and `codex.reasoning_effort` values are present in the code-owned Codex
  catalog snapshot and the model/effort combination is supported.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: runtime-only secret from canonical env `LINEAR_API_KEY`; never persisted
- `tracker.project_slug`: string, REQUIRED when `tracker.kind=linear`; configured per project in
  the Project settings record (each enabled project names its own Linear project slug)
- `tracker.active_states`: list of strings, default `["Todo", "Ready", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Canceled", "Cancelled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: instance-owned shell script or null
- `hooks.before_run`: instance-owned shell script or null
- `hooks.after_run`: instance-owned shell script or null
- `hooks.before_remove`: instance-owned shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_failure_retries`: non-negative integer, default `3`
- `codex.command`: app-server launch shell command, default `codex app-server`; model/effort CLI
  overrides are invalid
- `codex.model`: optional string selector from `SymphonyElixir.Codex.ModelCatalog`; absent sends no
  `turn/start` model override
- `codex.reasoning_effort`: optional string selector from `SymphonyElixir.Codex.ModelCatalog`;
  absent sends no `turn/start` effort override
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`
