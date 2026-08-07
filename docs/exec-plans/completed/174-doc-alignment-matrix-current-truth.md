# 174 Documentation Alignment Matrix Current Truth

## Goal

Make `docs/documentation_alignment.md` reflect the current shipped state after plans 158-172.

## Status

Completed.

## Background

The alignment matrix is supposed to be the checklist for keeping product direction, architecture, operator docs, and active plans consistent. It now has stale entries after recent completions:

- Analytics is still described as planned by active 158 in the canonical table.
- Reverse-proxy/Kubernetes work is still tied to active 159.
- GitHub README work is still tied to active 161.
- Boundary/test refactors still list active 162-172 even though those plan files moved to completed.
- The "Stale Or Conflicting Statements Found In Plan 160" table still uses active-plan wording for items that have now completed or moved.

When the checklist is stale, future agents use the wrong source of truth.

## Scope

- Update the matrix table to mark completed plan numbers and current behavior.
- Keep any residual work explicitly named as residual rather than implying the original active plan still owns it.
- Add entries for known residual test-harness and boundary cleanups only if new active plans exist for them.
- Ensure "current truth" columns are product facts, not implementation aspirations.

## Out of Scope

- Changing README content directly except through separate doc cleanup work.
- Updating code.
- Reopening completed plans.
- Turning the matrix into a roadmap.

## Acceptance Criteria

- The matrix distinguishes shipped analytics from future analytics enhancements.
- Completed deployment/README/refactor plans are referenced as completed.
- Residual work links to current active execplans, not completed plans with broad completion deviations.
- The matrix can be used as a reliable review checklist again.

## Verification

- `rg -n "active 158|active 159|active 160|active 161|active 162|active 172|planned by active plan 158|planned by active plan 159" docs/documentation_alignment.md`
- `rg -n "158|159|160|161|162|172" docs/documentation_alignment.md`
- `mix exec_plans.check`

