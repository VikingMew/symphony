# 243 Merge path-safety algorithms into PathSafety

## Goal

Collapse three hand-written copies of the canonical-descendant/symlink-escape check into one
primitive in `PathSafety`, locked by table-driven tests.

## Status

Active.

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

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix credo --strict` (0 [F]; existing [R]/[D] unchanged)
- `mise exec -- mix specs.check`
- `mise exec -- mix test` (682 baseline, 0 failures, 2 skipped; known flaky:
  CoreTest persistence race + WorkflowStoreTest — run in isolation
  to confirm non-regression)
- `mise exec -- mix docs.check` (if docs touched)
- `mise exec -- mix exec_plans.check`
- diff review: only whitelisted files changed

## Completion Deviations

To be filled after implementation.

