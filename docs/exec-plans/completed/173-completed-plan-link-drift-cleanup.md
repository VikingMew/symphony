# 173 Completed Plan Link Drift Cleanup

## Goal

Fix stale long-lived documentation references that still link completed work as active plans.

## Status

Completed.

## Background

The exec-plan lifecycle has advanced quickly. Plans 158-172 are now in `completed/`, but several long-lived documents still refer to active paths or active wording for that work.

Observed examples include:

- `README.md` still links plan 158 through `docs/exec-plans/active/158-runtime-results-analytics-page.md`.
- `docs/documentation_alignment.md` still describes 158, 159, 161, and 162-172 as active.
- `docs/documentation_alignment.md` says historical analytics is planned by active plan 158 even though plan 158 is completed and `/analytics` exists.

This creates a project-navigation bug: readers following docs can land on missing paths or misunderstand whether shipped behavior is still planned.

## Scope

- Audit long-lived docs for `docs/exec-plans/active/158` through `active/172`.
- Replace active links with completed links where the plan is completed.
- Change "planned" wording to "implemented" only when the completed plan and current code prove it.
- Keep genuinely future work described as future work.
- Add a small check or grep-based verification for stale `active/NNN` references when the plan file exists only under `completed/`.

## Out of Scope

- Changing product behavior.
- Rewriting docs broadly.
- Updating code comments that are only historical implementation notes.
- Changing the exec-plan archive rules.

## Acceptance Criteria

- No long-lived doc points to `docs/exec-plans/active/158` through `active/172`.
- Documentation alignment matrix matches the current plan lifecycle.
- Analytics, reverse-proxy/deployment, README rewrite, and boundary/test refactor status claims use current completed/planned wording.
- Broken active-plan links do not remain in README or canonical docs.

## Verification

- `rg -n "exec-plans/active/(158|159|160|161|162|163|164|165|166|167|168|169|170|171|172)|active 158|active 159|active 160|active 161|active 162|active 172" README.md docs`
- `mix exec_plans.check`
- `git diff --check`

