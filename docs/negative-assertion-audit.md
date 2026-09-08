---
title: Negative Assertion Audit
genre: reference
domain: [testing]
status: current
language: en
updated: 2026-09-08
---

# Negative Assertion Audit

This audit records the SYM-67 baseline and disposition of negative ExUnit
assertions. The machine-readable inventory is
[`negative-assertion-inventory.tsv`](negative-assertion-inventory.tsv).

## Reproduction

Generate the inventory from repository root:

```bash
elixir scripts/negative_assertion_inventory.exs > docs/negative-assertion-inventory.tsv
```

The original baseline scan was:

```bash
rg -n '\b(refute(_match|_in_delta|_receive)?|flunk)\b' test
```

It found 450 rows: 380 `refute`, 22 `refute_receive`, and 48 `flunk`.
Therefore 428 rows were non-temporal. The historical number 333 is not used as
an acceptance baseline.

## Disposition rules

- `refute_receive` remains unchanged because it expresses a mailbox waiting
  bound.
- Security redlines remain negative only when a nearby test comment cites the
  owning contract and risk.
- Deployment/configuration assertions state required capabilities positively;
  explicit security isolation remains a cited redline.
- Structure/data assertions use exact expected values or exact collections.
- Incidental string and implementation-detail exclusions are deleted or
  replaced with a stable positive signal.
- Failure-only control-flow branches are replaced with explicit success-shape
  matches where practical.

Regenerate the inventory after edits to obtain final retained counts and verify
that every remaining non-temporal row has a contract citation in its source
context.

## Final audit

The post-change scan contains 111 rows: 22 unchanged `refute_receive` timing
bounds, 41 cited `refute` security/protocol redlines, and 48 cited `flunk`
control-flow failures. Of the 428 baseline non-temporal rows, 198 were rewritten
as exact expected values or stable positive signals, 141 incidental string or
deployment
implementation-detail assertions were deleted, and 89 documented redline or
explicit-failure assertions were retained. Every retained non-temporal macro
has an adjacent owning-contract comment.

The deployment review specifically retains database, credential,
container-control, and mutable-image exclusions as security boundaries. Worker
capability remains asserted positively, including `LINEAR_API_KEY`, worker role,
Panel URL, registration token, read-only filesystem, dropped capabilities, and
dedicated workspace/cache/log volumes.
