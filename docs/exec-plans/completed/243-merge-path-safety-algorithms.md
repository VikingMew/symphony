# 243 Merge path-safety algorithms into PathSafety

## Goal

Collapse three hand-written copies of the canonical-descendant/symlink-escape check into one
primitive in `PathSafety`, locked by table-driven tests.

## Status

Completed.

## Background

Source: REFACTOR_REVIEW.md M3. The same algorithm — canonicalize roots, reject exact root,
judge descendant, distinguish symlink escape vs outside-root — is hand-written in
`workspace.ex:1034-1059`, `codex/app_server.ex:184-259`, and
`workspace_cleanup_policy.ex:18-52, 91-110`, each with `String.starts_with?(path <> "/",
root <> "/")` and root-list reduction. Allowed roots and error types legitimately differ per
boundary, but the safety algorithm is duplicated; a future symlink/path-boundary fix could patch
only one site. Violates Linus "remove complexity" and Carmack (safety invariants must not drift).

## Scope

- Add to `PathSafety` (path_safety.ex:1-48) one primitive: "is this canonical path strictly inside
  at least one canonical root" (exact-root excluded), with symlink-escape detection.
- `Workspace`, `AppServer`, `WorkspaceCleanupPolicy` call the primitive; each keeps its own
  policy wrapper, allowed-roots source, and error mapping.
- Do NOT merge local/remote policy; do NOT build a configurable generic policy DSL.

## Out of Scope

- Changing any boundary's actual allow/deny behavior or error messages.
- The workspace-disk-guard work (plan 238).

## Acceptance Criteria

- Table-driven tests pass: exact root, nonexistent leaf, relative symlink, absolute symlink,
  outside-root, empty-root list — identical behavior before/after at all three call sites.
- `grep 'starts_with?(path <>'` -> zero hits (all through PathSafety).

## Test Cases

- New table-driven PathSafety test (the 6 scenarios above).
- Existing workspace/app_server/cleanup-policy security tests unchanged and green.

## Implementation Notes

Behavioral lock FIRST (table tests), then swap call sites one at a time, running the per-site
security tests after each swap.

## Dependencies

- None.

## Verification

- `mise exec -- mix format --check-formatted` — PASS
- `mise exec -- mix compile --warnings-as-errors` — PASS
- `mise exec -- mix credo --strict` — PASS (0 [F]; 20 [R] + 1 [D], unchanged from plan 247)
- `mise exec -- mix specs.check` — PASS
- `mise exec -- mix test` — 703 tests, 1 failure (full suite). The single failure is the KNOWN
  flaky OrchestratorStatusTest timeout (documented in the plan baseline); the file passes in
  isolation (41 tests, 0 failures). Not related to this plan (touches no orchestrator code).
- `mise exec -- mix docs.check` — PASS (30 passed)
- `mise exec -- mix exec_plans.check` — PASS
- diff review: only whitelisted files changed (path_safety.ex + 3 call-site modules +
  path_safety_test.exs (new) + source_preparation_test.exs)
- grep acceptance: no direct `String.starts_with?(path <> "/", root <> "/")` checks remain in
  workspace.ex / app_server.ex / workspace_cleanup_policy.ex (all through PathSafety)

## Completion Deviations

- New `PathSafety.classify_strict_descendant/3`: canonical path + expanded path + root list ->
  `{:inside, root} | {:exact_root, root} | {:symlink_escape, root} | :outside`, with the
  strict-descendant logic (`strictly_inside?/2`, exact-root excluded) private to PathSafety.
- Workspace (remove/cleanup), AppServer (validate_workspace_against_roots) and
  WorkspaceCleanupPolicy now case-dispatch on the classification; each boundary keeps its own
  error mapping (workspace_symlink_escape / invalid_workspace_cwd:{:workspace_root | :symlink_escape
  | :outside_workspace_root} / cleanup semantics). No local/remote policy merged, no policy DSL.
- New table-driven path_safety_test.exs (exact root, nonexistent leaf, relative symlink, absolute
  symlink, outside-root, empty-root list) + workspace symlink-escape error-mapping test.
  Test baseline 701 -> 703 (+2).

