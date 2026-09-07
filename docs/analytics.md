---
title: Analytics Operations
genre: guide
domain: [operations, analytics]
status: current
language: en
---

# Analytics Operations

`/analytics` reads persisted PostgreSQL issues, runs, and events for the selected 24-hour, 7-day, 30-day, or all-time range. Dedicated analytics reads are not subject to the general UI list limit. Persistence failure is shown as **Data unavailable**, never as zero.

The issue cohort contains unique issues with an issue run in range. Refinement rounds count refinement-profile runs, not continuation turns. Blocked rate counts each issue once when a ranged run/event is blocked or its latest issue record has a blocking decision. Description length uses the Unicode length of the latest observed snapshot and reports missing descriptions separately.

The first-handoff cohort is selected by a transition to `Ready to Merge` occurring in range. A later `Ready to Merge -> In Progress` transition through report generation is an observed return; absence of that evidence is pending/censored, not a pass. Rework means an observed return or repeated implementation handoff. These are workflow proxies, not GitHub review, check, or diff metrics.

Origin is agent-created only when a successful `linear_issue_create` audit proves it. Everything else is external/unknown; no audit coverage is reported as insufficient. Token rows take the maximum canonical cumulative absolute snapshot per run and group by profile and issue. Operator runs, rate-limit percentages, and monetary cost are excluded.

The optional `analytics` workflow section accepts `refinement_rounds_average_max`, `first_handoff_observed_return_rate_max`, `blocked_rate_max`, `latest_description_length_min`, `rework_rate_max`, and `per_issue_total_tokens_max`. Rate values are decimals from 0 to 1. Thresholds only add presentation warnings; they never gate dispatch or mutate Linear or blocking decisions.
