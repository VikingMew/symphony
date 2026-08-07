# 112 Helper Migration Completion

Status: Completed

## Goal

Finish the helper-migration debt identified by plan 111 so repeated low-level helper logic has one owning module, and local wrappers remain only when they encode domain behavior.

## Background

Plans 109 and 111 introduced shared helpers:

- `SymphonyElixir.Shell`
- `SymphonyElixir.Payload`
- `SymphonyElixir.StateName`
- `SymphonyElixir.Redaction`

The first migration slice removed the most direct `shell_escape/1`, `map_value/3`, `map_path/3`, and mixed atom/string `Map.get(...) || Map.get(...)` duplicates. Remaining debt is mostly local wrappers for blank checks, state normalization, and domain-specific sanitization functions.

## Scope

- Inventory remaining local helper functions in production code:
  - `blank?/1`
  - `normalize_issue_state/1`
  - `sanitize_*`
  - direct mixed atom/string payload access
- Replace direct semantic matches with shared helpers.
- Keep local wrappers only when the function name explains the domain-specific behavior, such as history metadata sanitization or Linear GraphQL error-body sanitization.
- Add or update tests for helper contracts touched by the migration.
- Update plan 111 if this work closes one of its transferred debts.

## Out of Scope

- Large module decomposition.
- Changing runtime behavior or log/message wording except where needed to preserve equivalent helper output.
- Replacing domain-specific validation logic with generic helpers.

## Acceptance Criteria

- No private `shell_escape/1`, `map_value/3`, or `map_path/3` exists outside the shared helper modules.
- Mixed atom/string payload lookup in orchestration, status, persistence, and web-facing paths uses `SymphonyElixir.Payload` unless a local domain adapter is explicitly named.
- Shared credential, ANSI/control-byte, URI userinfo, and bounded-output redaction uses `SymphonyElixir.Redaction`.
- Remaining local `sanitize_*`, `blank?/1`, and state-normalization helpers are documented by name or replaced with shared helpers.
- Existing tests pass with coverage still at or above the project threshold.

## Test Cases

- Unit tests for `Shell`, `Payload`, `StateName`, and `Redaction`.
- Focused regression tests for modules whose helper behavior changes.
- `mix lint`
- `mix test --cover`

## Implementation Notes

- Prefer mechanical call-site replacements first.
- Do not change external API shapes or persisted payloads.
- Avoid converting arbitrary strings to atoms unless the current behavior already depends on existing atoms.

## Verification

- `rg` inventory for private helper names and mixed-key payload access.
- Added `SymphonyElixir.Text` for shared strict and form-style blank checks.
- Replaced equivalent `blank?/1` implementations in config, Codex startup, Linear discovery/diagnostics, workspace, run history, and AdminLive with shared text helpers or thin local adapters.
- Removed the remaining direct `shell_escape/1`, `map_value/3`, `map_path/3`, and obvious mixed atom/string payload lookup duplicates in the earlier completion slice.
- Kept domain-specific sanitizers where their names describe the boundary: history metadata sanitization, retry error summarization, hook output log bounding, Linear GraphQL error-body sanitization, and Git command failure shaping.
- Added/updated focused helper tests.
- `mix format --check-formatted`
- `mix lint`
- `mix test --cover`

## Completion Deviations

- Remaining local `sanitize_*` functions are deliberately retained where they encode domain-specific output shape, not only shared redaction. They call shared helpers where the shared behavior is the direct match.
- Thin local `blank?/1` wrappers remain in a few modules to preserve readable domain call sites, but delegate to `SymphonyElixir.Text`.

## Dependencies

- Plan 109 shared helper modules.
- Plan 111 audit findings.

## Handoff Notes

Start with `rg` for `defp blank?`, `normalize_issue_state`, `sanitize_`, `Map.get(... "key") || Map.get(... :key)`, and any remaining private helper names. Treat semantic equivalence carefully; sanitizers often encode domain-specific output rules.
