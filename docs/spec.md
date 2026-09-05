---
title: Symphony Service Specification
genre: spec
domain: [spec, overview]
status: current
language: en
owner: SymphonyElixir
updated: 2026-08-27
---

# Symphony Service Specification

## Specification Domains

The service specification is split into domain files (L4 contracts); this document is the
normative overview. Cross-file references use `§N` against the original section numbering.

- [Domain Model and Reference Algorithms](spec-domain-model.md) — entities, stable identifiers,
  normalization, reference algorithms (§4, §16)
- [Workflow and Configuration](spec-workflow-config.md) — persisted runtime contract, package
  format, configuration resolution and reload semantics (§5-6)
- [Orchestration](spec-orchestration.md) — issue state machine, polling/scheduling/reconciliation,
  workspace management and safety (§7-9)
- [Agent Runner Protocol](spec-agent-runner.md) — coding-agent launch and streaming contract,
  prompt construction, SSH worker extension (§10, §12, Appendix A)
- [Issue Tracker Integration](spec-linear-integration.md) — Linear-compatible operations, query
  semantics, normalization and error contract (§11)
- [Logging and Observability](spec-observability.md) — logging conventions, sinks, metrics, token
  accounting, optional HTTP surface (§13)
- [Reliability and Security](spec-reliability-security.md) — failure classes, recovery, security
  and operational safety invariants (§14-15)
- [Test and Validation Matrix](spec-conformance.md) — conformance profiles, validation matrix,
  implementation checklist (§17-18)

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps project settings and profiles in an active workflow record and uses an immutable,
  code-owned workflow policy. Implementations MAY import/export a split package format for
  portability, but its workflow-policy keys are not a runtime source.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner with a narrow centralized implementation-handoff boundary.
- Restricted agent tools request ticket mutations. For implementation completion, Symphony first
  ensures an open GitHub PR for the validated repository/base/head tuple and only then performs the
  final Linear comment/reference/state writes.
- The default successful implementation run ends at `Ready to Merge`. Symphony then permits only
  the durable, read-only post-handoff review job for that immutable PR head; ordinary issue
  dispatch remains disabled. `Done` is reached later through Linear's GitHub merged-PR automation.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from the project's current persisted workflow.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- General project-specific business logic for tickets or PRs. The required atomic GitHub
  PR-before-Linear implementation handoff is a deliberate backend invariant.
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads the project's current persisted workflow.
   - Parses the stored workflow config and prompt/profile data.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (service-defined, optionally package-backed)
   - Active workflow prompt and profile data.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses active workflow config into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `tracker.kind: linear` in this specification version).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the targeted Codex app-server mode.
- Host environment authentication for the issue tracker and coding agent.
