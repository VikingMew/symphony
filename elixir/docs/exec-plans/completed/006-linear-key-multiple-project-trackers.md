# Task 006: Linear Key With Multiple Project Trackers

## Status

**Status**: Completed
**Priority**: MEDIUM
**Dependencies**: Task 002, Task 003, Task 005 recommended
**Created**: 2026-05-01

## Goal

Support one Linear API key being used across multiple Symphony project trackers, where each tracker can target a different Linear project and maintain its own workflow/project configuration.

## Background

The current workflow model assumes one Linear project slug in a single `WORKFLOW.md`. Long term, Symphony should manage multiple projects from one Web service. A single Linear personal API key or service credential may have access to multiple Linear projects.

Operators should be able to configure multiple Symphony projects, each with its own Linear project slug, active states, terminal states, workspace rules, and workflow version.

## Scope

- Add first-class project/tracker configuration for multiple Linear projects.
- Allow a shared Linear API key secret reference across project trackers.
- Support per-project Linear project slug.
- Support per-project active states and terminal states.
- Update polling/orchestration so projects are polled independently.
- Keep per-project concurrency limits.
- Ensure runs, issues, events, and workflow versions are associated with a project.
- Add UI support if Task 005 has landed.

## Out of Scope

- Multiple Linear workspaces with separate API keys, unless the schema naturally supports it.
- Per-user authorization to individual projects.
- Cross-project scheduling optimization.
- Non-Linear tracker support.

## Acceptance Criteria

- [ ] Operators can configure at least two Symphony projects using the same Linear key secret reference.
- [ ] Each project can target a different Linear project slug.
- [ ] Each project can define its own active and terminal states.
- [ ] Orchestrator polling keeps project state separate.
- [ ] Runs and events are associated with the correct project.
- [ ] A failure in one project tracker does not stop polling for other projects.
- [ ] Tests cover multiple project configs, shared key usage, independent polling, and project-scoped run records.

## Test Cases

- Two project configs can reference the same Linear API key secret reference.
- Each project stores a different Linear project slug.
- Each project stores independent active and terminal states.
- Polling project A does not read or mutate project B runtime state.
- Project A tracker failure records an error without stopping project B polling.
- Runs created from project A and project B are scoped to the correct project IDs.
- Events created during polling/dispatch include the correct project ID.
- Per-project concurrency limit is enforced independently.
- Existing single-project configuration still works.
- UI project/tracker settings can display shared key reference without exposing the key value, if Task 005 has landed.

## Implementation Notes

- Model Linear credentials as secret references, not duplicated plaintext values.
- Keep tracker config separate from workflow version but link both to the same project.
- Decide whether each project gets its own orchestrator child process or whether one orchestrator loops over project configs.
- Prefer project-scoped status/events from the start; Task 007 will need this for better dashboard pages.
- Keep the single-project path simple for local development.

## Verification

- Focused tests for multiple project tracker config.
- Focused orchestrator tests with memory tracker equivalents for two projects.
- `mise exec -- mix test test/symphony_elixir/core_test.exs`
- `mise exec -- mix test`
- Manual check with two test Linear projects if credentials are available.

## Completion Deviations

- Implemented the persistence model for multiple projects and tracker configs with shared secret references.
- Project-scoped persisted runs and events are supported.
- Full independent multi-project Linear polling remains a follow-up: the current orchestrator still dispatches from one active runtime workflow at a time.

## Handoff Notes

- Record whether implementation uses one orchestrator process or project-specific child processes.
- Record how shared Linear key references are represented.
- Record remaining limitations for multiple Linear workspaces or multiple credentials.
