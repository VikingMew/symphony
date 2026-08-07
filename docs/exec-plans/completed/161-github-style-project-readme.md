# 161 GitHub Style Project README

## Goal

Rewrite the repository README into a clear GitHub-style project README that accurately reflects Symphony's current product, architecture, setup flow, operating model, and roadmap.

The README should help a new reader quickly understand what the project is, what problem it solves, how to run it, how it is configured, what is production-ready, and where deeper documentation lives.

## Status

Completed.

## Background

The project has evolved substantially through the exec-plan archive:

- database-first runtime configuration;
- Linear-driven workflow automation;
- Codex app-server execution;
- staged profiles for refinement, implementation, and merge;
- project/worktree source management;
- persisted runs/events/session history;
- dashboard, run detail, Linear diagnostics, Settings, Workers, Events, and planned Analytics;
- input-required blocked sessions;
- reverse proxy/Kubernetes deployment direction;
- extensive internal architecture and long-term docs.

The existing top-level README and Elixir README may no longer present the project in a cohesive GitHub-facing way. A new reader should not need to inspect dozens of exec plans to understand the system. The README should be high-signal, current, and honest about implemented vs planned features.

This plan depends on the broader documentation alignment work in plan 160, but it is specifically about producing a polished project README suitable for GitHub.

## Scope

- Audit the current root `README.md`, `elixir/README.md`, `ARCHITECTURE.md`, `SPEC.md`, and long-term docs for README-worthy content.
- Write or rewrite the root `README.md` in a modern GitHub project style.
- Include concise sections:
  - project name and one-sentence description;
  - what Symphony does;
  - core concepts;
  - current feature list;
  - architecture overview;
  - quick start;
  - configuration model;
  - operating modes;
  - dashboard/observability surfaces;
  - deployment notes;
  - development commands;
  - documentation map;
  - project status and roadmap;
  - contribution/testing expectations.
- Clearly distinguish implemented features from active/planned work.
- Link to deeper docs instead of duplicating all details.
- Keep examples consistent with current runtime truth:
  - database-backed active workflow is runtime truth;
  - `workflow.yml` and `profiles.yml` are import/export artifacts;
  - Settings owns runtime configuration;
  - centralized execution is supported;
  - worker-backed execution and SSH worker behavior are described accurately;
  - reverse proxy/Kubernetes support is documented as implemented only after plan 159 completes, otherwise as planned.
- Avoid stale setup instructions, obsolete flags, or local-file runtime claims.

## Out of Scope

- Do not rewrite every long-term doc in this plan.
- Do not implement new product features.
- Do not create marketing copy that overstates current capabilities.
- Do not remove detailed docs that still serve as deep references.
- Do not change runtime configuration or code behavior.

## Acceptance Criteria

- Root `README.md` reads like a complete GitHub project README.
- The README accurately describes the current project state.
- The README includes a working quick-start path for local development.
- The README links to the right deeper docs for architecture, deployment, workflow configuration, Linear integration, and observability.
- Implemented vs planned features are clearly labelled.
- The README does not claim local workflow files are runtime source.
- The README does not claim Symphony owns public TLS/domain support if that is delegated to reverse proxy/Kubernetes.
- The README does not imply worker mode is required for centralized execution.
- `git diff --check` passes.

## Test Cases

- New-reader scan:
  - first screen explains what Symphony is and why it exists.
- Setup scan:
  - quick start includes prerequisites and commands that match current repo tooling.
- Configuration scan:
  - README points users to Settings/database-backed workflow configuration.
- Deployment scan:
  - README identifies all-in-one, dashboard, worker/SSH, reverse-proxy/Kubernetes status correctly.
- Observability scan:
  - README lists Dashboard, Runs, Events, Linear diagnostics, Workers, and planned Analytics appropriately.
- Stale phrase search:
  - no obsolete guardrails flag instructions;
  - no file-backed runtime fallback claim;
  - no misleading standalone HTTP worker client claim if not implemented.

## Implementation Notes

Treat the README as a top-level entry point, not as exhaustive documentation.

Suggested outline:

```markdown
# Symphony

Short description.

## What It Does
## Core Concepts
## Features
## Quick Start
## Configuration
## Operating Modes
## Observability
## Deployment
## Development
## Documentation
## Status / Roadmap
```

Prefer concise prose and links. Use tables where they make operational differences clear, for example implemented vs planned features or deployment modes.

Coordinate with plan 160 so README claims do not diverge from long-term docs.

## Verification

- Manual review against current completed/active exec plans.
- `rg` checks for known stale phrases.
- `git diff --check`
- If commands are included, run or verify them against the current repo where practical.
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Rewrote the root README as the GitHub entry point and linked the new reverse proxy/Kubernetes deployment guide. The README now treats SQLite Settings as runtime truth and labels the current alpha status explicitly.

## Dependencies

- Active plan 160 for exec-plan and long-term documentation alignment.
- Existing root docs and `elixir/README.md`.
- Completed exec-plan archive through current runtime and UI work.

## Handoff Notes

The README should be honest and useful. It should tell a new engineer or operator what they can do today, where the sharp edges are, and which docs to open next.
