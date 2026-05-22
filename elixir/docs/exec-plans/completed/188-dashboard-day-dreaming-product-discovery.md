# 188 Dashboard Day Dreaming Product Discovery

## Goal

Add a Dashboard button named `Day dreaming` that starts or queues a dedicated product-discovery agent task.

The day dreaming task reads the existing code and long-term documentation, compares implementation reality with product direction, and creates one Linear backlog issue per feature or optimization opportunity.

The core day dreaming instruction is:

> 读取现有代码和长期文档，结合代码和文档，这个项目还有什么需要开发和优化的功能，一个优化点新建一个backlog的linear issue，不要修改代码和文档，只生成新的issue。

## Status

Completed.

## Background

Plan 184-187 define `nap` as a technical-debt/code-smell audit flow. This plan intentionally reserves `day dreaming` for a different purpose: forward-looking product and feature discovery.

Nap asks "what is messy, inconsistent, redundant, or technically weak?" Day dreaming asks "given the codebase and long-term direction, what useful product capabilities or improvements should be built next?"

The two flows may share runtime infrastructure and Linear issue creation plumbing, but they must remain separate profiles, prompts, task kinds, Dashboard labels, and result categories.

## Scope

- Add a Dashboard button labeled `Day dreaming`.
- Add a distinct runtime task kind, for example `:day_dreaming_discovery`.
- Add a dedicated `day_dreaming` profile.
- Reuse the same single-slot queue semantics as `Take a nap` unless plan 184 implements a more general task queue:
  - start immediately if no active work is running;
  - queue one request if active work exists;
  - start after active work reaches zero;
  - repeated clicks while queued/running do not create duplicates.
- Add Dashboard status for day dreaming:
  - idle;
  - queued;
  - starting;
  - running;
  - completed;
  - failed.
- Ensure the prompt requires reading:
  - current code structure;
  - current README and architecture docs;
  - long-term direction docs;
  - relevant active/completed exec plans when useful.
- Ensure output is issue-only:
  - no code edits;
  - no documentation edits;
  - no commits;
  - no pull requests.
- Create one Linear backlog issue per distinct feature or optimization opportunity.
- Each created issue should include:
  - concise title;
  - opportunity/problem statement;
  - evidence from current code/docs;
  - why it matters;
  - suggested product/engineering direction;
  - rough priority or impact;
  - source day dreaming run id.
- Reuse or extend the restricted Linear issue creation path from plan 186, but keep profile authorization separate from `nap`.
- Record final summary with created/skipped/failed counts and issue links.

## Out of Scope

- Technical-debt, redundant-code, compatibility-code, or bad-smell audit. Owned by the nap flow.
- Modifying code or documentation.
- Creating implementation PRs.
- Automatically ranking roadmap items with a complex scoring system.
- Cross-run semantic duplicate detection beyond simple title/fingerprint checks.
- Replacing long-term direction docs.
- Merging day dreaming and nap into one generic audit profile.

## Acceptance Criteria

- Dashboard renders a `Day dreaming` button separate from `Take a nap`.
- Clicking `Day dreaming` starts or queues a `day_dreaming` task without affecting nap state.
- The runtime state/API distinguishes nap and day dreaming statuses.
- Day dreaming uses profile id `day_dreaming`, not `nap`, refinement, implementation, or merge.
- Day dreaming prompt includes the exact issue-only product-discovery intent.
- Day dreaming can create Linear backlog issues through the restricted issue creation boundary.
- Created issues are product/feature/optimization opportunities, not direct code-smell cleanup tickets.
- Missing/invalid backlog state prevents issue creation and surfaces a visible error.
- Repeated clicks while queued/running are idempotent.
- No code or documentation changes are allowed; dirty-worktree enforcement applies as in nap.
- Tests cover button rendering, queue behavior, profile selection, issue creation authorization, and result summary.

## Test Cases

- Dashboard render includes both `Take a nap` and `Day dreaming`.
- Clicking `Day dreaming` with no active tasks starts one day dreaming runtime task.
- Clicking `Day dreaming` while active work exists queues one day dreaming request.
- Clicking `Day dreaming` twice while queued creates only one queued request.
- Running `Take a nap` does not satisfy or consume a queued `Day dreaming` request.
- Running `Day dreaming` does not satisfy or consume a queued nap request.
- Build prompt for profile `day_dreaming`; assert it includes:
  - code and long-term docs reading requirement;
  - feature/optimization discovery goal;
  - one Backlog Linear issue per opportunity;
  - no code/doc edits.
- Issue create tool allows profile `day_dreaming` only for the product-discovery schema/category set.
- Dirty worktree after a day dreaming run fails the run visibly.
- Final summary renders created/skipped/failed counts and created issue URLs.

## Implementation Notes

- Use internal spelling `day_dreaming` for profile/task ids, and UI label `Day dreaming`.
- Keep this separate from `nap`; do not alias one to the other.
- If plan 184 introduces a generic operator-triggered task queue, day dreaming should register as another task kind instead of duplicating queue code.
- The prompt should prefer product opportunities backed by evidence from both code and long-term docs. Pure speculation should be rejected or turned into a lower-confidence issue.
- The issue create payload may need a category such as:
  - missing feature;
  - product gap;
  - operator UX improvement;
  - observability improvement;
  - deployment/runtime improvement;
  - documentation/product alignment.
- Apply the same no-edit backend guardrails as nap.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs`
- `mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- `mise exec -- mix test test/symphony_elixir/prompt_builder_test.exs`
- `mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_test.exs`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

Implemented the Dashboard control, runtime task state, default `day_dreaming` profile, issue-create authorization, and summary display alongside the nap flow. It shares the operator-task shell rather than adding a separate background executor.

## Dependencies

- [184-dashboard-nap-control-and-queue.md](active/184-dashboard-nap-control-and-queue.md)
- [185-nap-profile-and-readonly-contract.md](active/185-nap-profile-and-readonly-contract.md)
- [186-nap-linear-issue-create-tool.md](active/186-nap-linear-issue-create-tool.md)
- [187-nap-audit-results-and-dedup.md](active/187-nap-audit-results-and-dedup.md)
- [160-execplans-long-term-docs-alignment.md](../completed/160-execplans-long-term-docs-alignment.md)
- [174-doc-alignment-matrix-current-truth.md](active/174-doc-alignment-matrix-current-truth.md)

## Handoff Notes

Day dreaming is a product-discovery mode. It should create roadmap-quality backlog issues, not technical-debt cleanup issues. Keep the wording, profile id, task kind, categories, and Dashboard status separate from nap so the two buttons can evolve independently.
