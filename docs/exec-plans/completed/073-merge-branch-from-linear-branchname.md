# 073 Merge Branch From Linear BranchName

## Goal

Implement a backend-owned merge flow that reads Linear `branchName` as the branch to merge, runs the configured repository merge operation, records observable run events, and transitions Linear through workflow-allowed states.

## Status

Completed.

## Background

Implementation work already reads Linear issue metadata, including `branchName`, into `SymphonyElixir.Linear.Issue.branch_name`. Implementation and merge must use that same Linear-provided branch name. The implementation run must work on and push `branchName`; the merge run must verify that the branch exists on the remote before attempting to merge it.

This avoids introducing a second Symphony-owned branch naming contract. Linear remains the source of truth for the branch associated with an issue. Symphony's responsibility is to validate that the value exists and is safe enough to pass to git, make implementation use it, verify that it was pushed, then execute an observable merge flow.

## Scope

- Add merge-profile runtime dispatch for merge-routed states, for example `Ready to Merge`.
- Read the merge branch from `issue.branch_name`, which is populated from Linear `branchName`.
- Treat missing or blank `branchName` as a hard precondition failure before running git commands.
- Ensure implementation runs use the same Linear `branchName`:
  - implementation startup must validate `issue.branch_name`;
  - workspace setup must check out/create the local work branch using that branch name;
  - Codex prompts must state the required branch name and must not invent another branch;
  - implementation completion must record evidence that this branch was pushed.
- Add implementation completion preflight before requesting a merge-ready state:
  - verify `git rev-parse --verify HEAD` locally;
  - verify the remote branch exists, for example `git ls-remote --heads <remote> <branchName>`;
  - record the remote commit sha or branch URL when available;
  - fail or refuse the merge-ready transition if the Linear branch has not been pushed.
- Validate `branchName` before use:
  - must be ASCII;
  - must not contain whitespace;
  - must not start with `-`;
  - must not contain unsafe Git ref fragments such as `..`, `@{`, `\`, `~`, `^`, `:`, `?`, `*`, `[`;
  - must pass a deterministic branch/ref validator in tests.
- Prepare a clean workspace from the configured `project.repository_url`.
- Check out the configured base branch, normally `project.default_branch`.
- Verify the Linear branch name exists on the remote before merge.
- Fetch the Linear branch name from the remote.
- Merge the fetched branch into the base branch using a non-interactive git command.
- Make push behavior explicit in workflow/profile config:
  - default should be no push unless the merge profile enables it;
  - when enabled, push the updated base branch to the configured remote.
- Move Linear state only through configured workflow transitions:
  - optional backend transition into `Merging` when the merge run starts;
  - success transition to a configured success state such as `Done` or `Merged`;
  - failure leaves the issue in the current/rollback-safe state and records events.
- Add dashboard/session events for each merge phase:
  - branch validation;
  - remote branch existence check;
  - workspace preparation;
  - fetch;
  - checkout base;
  - merge;
  - optional push;
  - Linear transition.
- Add tests for implementation branch use, pushed-branch verification, merge dispatch, branch validation, git command ordering, push-disabled/push-enabled behavior, and Linear transition failures.

## Out of Scope

- Creating or updating Linear `branchName`.
- Deriving fallback branch names from issue identifiers or comments.
- Allowing implementation to use a branch different from Linear `branchName`.
- Marking implementation merge-ready without proving the Linear branch was pushed.
- Letting Codex perform the merge by prompt.
- Conflict resolution automation.
- Force push or history rewrite.
- Creating pull requests.
- Full GitHub/GitLab provider integration beyond generic git commands.

## Acceptance Criteria

- [x] A merge-routed issue with Linear `branchName` starts the backend merge flow.
- [x] A merge-routed issue without Linear `branchName` fails before workspace or git side effects.
- [x] Unsafe branch names are rejected before git commands.
- [x] Implementation runs validate and use Linear `branchName` as the required working branch.
- [x] Implementation prompts include the required Linear branch name and forbid creating a different task branch.
- [x] Implementation completion verifies that Linear `branchName` exists on the remote before requesting the merge-ready target state.
- [x] Merge refuses to run when the Linear branch does not exist on the remote.
- [x] Merge uses the configured repository URL and base/default branch.
- [x] Git commands run non-interactively and with bounded timeout/output capture.
- [x] Push is skipped by default unless enabled in merge config.
- [x] Push enabled runs only after merge succeeds.
- [x] Successful merge records branch/base metadata in run events.
- [x] Merge failure records sanitized status and recent output.
- [x] Linear state transitions use workflow policy and restricted Linear APIs.
- [x] If a Linear transition fails after merge success, the run reports a visible failure instead of silently succeeding.
- [x] Tests cover all required paths.

## Test Cases

- Merge dispatch:
  - issue state routes to merge profile;
  - issue has `branch_name: "feature/ccr-3"`;
  - backend merge executor is called instead of implementation Codex execution.
- Implementation branch enforcement:
  - implementation-routed issue has `branch_name: "feature/ccr-3"`;
  - prompt/context includes `feature/ccr-3` as the required branch;
  - workspace command runner checks out or creates that branch before Codex work.
- Implementation missing branch:
  - implementation-routed issue has no `branch_name`;
  - run fails before Codex startup and before `Ready -> In Progress`.
- Implementation pushed-branch verification:
  - Codex requests merge-ready target state;
  - remote branch check succeeds;
  - transition is allowed.
- Implementation not-pushed failure:
  - Codex requests merge-ready target state;
  - `git ls-remote --heads` does not find Linear `branchName`;
  - Symphony refuses the target state and records a visible error.
- Missing branch:
  - issue has `branch_name: nil`;
  - run fails with `missing_linear_branch_name`;
  - workspace/git adapters are not called.
- Unsafe branch:
  - issue branch is `feature/../../bad` or contains whitespace/non-ASCII;
  - validation fails before side effects.
- Successful merge without push:
  - fetch, checkout, merge commands succeed;
  - push config is disabled;
  - push command is not called;
  - success transition is requested.
- Successful merge with push:
  - merge succeeds and push config is enabled;
  - push runs after merge;
  - success transition is requested after push succeeds.
- Merge conflict/failure:
  - merge command exits non-zero;
  - success transition is not requested;
  - event contains sanitized recent output.
- Linear transition failure:
  - git merge succeeds;
  - Linear transition returns an error;
  - run records transition failure and does not report clean success.

## Implementation Notes

- Prefer a dedicated pure validator module for branch names and a dedicated merge executor module with injectable command runner.
- Do not pass untrusted branch names through shell interpolation. Use argv-style command execution where possible; if existing command helpers are shell-based, quote defensively and keep validator strict.
- Branch enforcement belongs in both phases:
  - implementation validates and uses `issue.branch_name`;
  - merge validates and fetches the same value.
- The remote existence check should be a backend precondition, not a prompt instruction. Codex may report push results, but Symphony must verify the branch before allowing merge-ready state or before merge execution.
- Reuse existing workspace preparation and non-interactive git environment rules from project bootstrap:
  - `GIT_TERMINAL_PROMPT=0`;
  - SSH batch mode for SSH remotes;
  - timeout;
  - recent-output capture;
  - sanitized events.
- Keep merge phase logging distinct from project bootstrap and Codex execution.
- The merge flow should not start Codex unless a future workflow explicitly defines an agent-assisted merge profile. This plan's merge path is backend-owned.
- The implementation flow can still be Codex-owned for code changes, but branch selection is backend-owned through Linear `branchName`.
- Config additions should be minimal and explicit, likely under the merge profile or workflow merge policy:
  - `base_branch`;
  - `push`;
  - `remote`;
  - `timeout_ms`;
  - `success_state`;
  - optional `start_state`.
- If config is absent, default to safe behavior: no push and no state transition beyond visible failure/success events unless workflow policy provides a valid target.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/merge_flow_test.exs`
- `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/dynamic_tool_test.exs`
- `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs`
- `mise exec -- mix test`
- `mise exec -- mix lint`
- `mise exec -- mix test --cover`
- `git diff --check`

## Completion Deviations

- Merge is implemented as a backend action for locally prepared workspaces. A future remote-worker merge executor can reuse the same `MergeExecutor` policy if worker-host-side merge execution is needed.
- Implementation branch enforcement is active when a project repository URL is configured. Non-repository workflows continue to run without git branch preparation.

## Dependencies

- Existing Linear `branchName` polling into `SymphonyElixir.Linear.Issue.branch_name`.
- Existing workflow profile routing for merge states.
- Existing implementation profile routing and implementation completion transition policy.
- Existing workspace/project repository bootstrap configuration.
- Existing restricted Linear transition boundary.
- Existing run events/session history observability.

## Handoff Notes

Linear `branchName` is the branch source of truth for both implementation and merge. If it is absent, unsafe, or not pushed to the remote, Symphony should fail early and visibly. Do not derive a fallback branch name, because that would risk implementing or merging a branch that Linear did not explicitly bind to the issue.
