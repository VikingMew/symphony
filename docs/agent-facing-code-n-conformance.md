---
title: Agent-Facing Code N Conformance Record
genre: reference
domain: [governance, code-quality, agents]
status: current
language: en
owner: SymphonyElixir.AgentCodeNCheck
updated: 2026-10-08
---

# Agent-Facing Code N Conformance Record

This L4 record stores current repository facts for N-01 through N-09. The
[Agent-facing code design](agent-facing-code-design.md#7-n-组导航门禁) owns checker and
ratchet mechanics; the [constitution](spec-agent-facing-code.md) owns shared definitions. A gate
does not imply that baselined stock is compliant.

## Clause record

The table has exactly nine clause rows. `partially_satisfied` means the deterministic gate blocks
new or expanded findings while exact stock remains in the initial baseline.

| Clause | Baseline status | Final status | Exact evidence | Implementation result | Repeatable execution | Remediation plan |
| --- | --- | --- | --- | --- | --- | --- |
| N-01 | partially_satisfied | partially_satisfied | `config/agent_code_navigation_baseline.yml`; AST locations in `mix agent_code_n.check --format json` | Module-tail, function, type, and fixture-helper symbols are checked per declaration category; repeated clauses of one symbol collapse before aggregation. | `mix agent_code_n.check --format json` | Rename or merge one exact baselined collision at a time and remove the same identity. |
| N-02 | partially_satisfied | satisfied | `AGENTS.md` Required Rules naming review item | Intent/role naming and the ban on encoded prefixes, type abbreviations, and Hungarian naming are a short human review rule. | Review changed declarations against `AGENTS.md`. | None. |
| N-03 | not_satisfied | partially_satisfied | `SymphonyElixir.AgentCodeNCheck`; focused normalization tests | Same-category names are normalized by the fixed sequence below and conflicts retain every original name and sorted location. | `mix test test/symphony_elixir/agent_code_n_check_test.exs` | Rename one exact baselined near-name family and delete the same identity. |
| N-04 | not_satisfied | satisfied | Glossary below; `AGENTS.md` single-term review item | The seven core terms have one repository meaning and prohibited new declaration synonyms. | Review changed declarations against the glossary. | None. |
| N-05 | partially_satisfied | partially_satisfied | N-05 identities in `config/agent_code_navigation_baseline.yml` | Every scanned Elixir file has one top-level main-module check and basename-to-module-suffix mapping, including dotted Mix task basenames. | `mix agent_code_n.check --format json` | Split or rename each baselined file/module mismatch and remove the exact identity. |
| N-06 | satisfied | satisfied | `find docs lib test config scripts .github -type d \| sort`; `AGENTS.md` directory review item | Date and numbered phase/stage/batch directories are machine-blocked; person names and other semantic stages remain human-reviewed. | `mix agent_code_n.check --format json` plus review of changed paths | None. |
| N-07 | partially_satisfied | satisfied | `AGENTS.md` Build, Run, and Test sections | The resident rules give current executable commands for all three groups and the checker verifies their entries. | `mix agent_code_n.check --format json` | None. |
| N-08 | partially_satisfied | partially_satisfied | N-08 identities in `config/agent_code_navigation_baseline.yml` | Top-level test modules, support namespaces, and helper/product declaration collisions are checked with exact locations. | `mix agent_code_n.check --format json` | Rename each baselined helper collision or product declaration and remove the exact identity. |
| N-09 | partially_satisfied | satisfied | `AGENTS.md` Navigation section | The checker verifies only the `docs/design.md` module-map link and executable `rg` entry; `mix docs.drift` owns validity and freshness. | `mix agent_code_n.check --format json`; `mix docs.drift` | None. |

Final totals are 5 satisfied, 4 partially satisfied, 0 not satisfied, and 0 not applicable. The
current baseline waterline is 555 exact findings; the N group is not fully compliant while that
value is nonzero.

## Deterministic rule definitions

N-03 applies these transforms in order: lowercase; remove `_`; then apply exactly one finite English
singular rule: consonant + `ies` becomes `y`, `ches`/`shes`/`xes`/`zes` loses `es`, or a final `s`
loses `s` unless the word ends in `ss`. No other stemming occurs.

N-05 scans `lib/**/*.ex`, `test/**/*.ex`, and `test/**/*.exs`. Each file must contain exactly one
top-level module. The extension-free basename is camelized and must equal the module suffix; dots
in Mix task basenames remain module segment boundaries.

N-06 rejects a directory segment equal to `YYYY-MM-DD`, `YYYYMMDD`, or a case-insensitive
`phase`, `stage`, or `batch` followed by an optional `_`/`-` and digits. N-08 treats top-level
modules outside `test/support` as tests that must end in `Test`; support modules must be under
`SymphonyElixir.TestSupport` or contain a `Fixtures` segment. Helper and fixture declarations may
not share a name with a product declaration.

## Glossary

The prohibited entry applies only when the proposed declaration means the concept in this row.

| Term | Single repository meaning | Prohibited new declaration synonym |
| --- | --- | --- |
| `issue` | Tracker work item and its stable identity. | `ticket` |
| `task` | One agent operation scheduled inside a run. | `job` |
| `run` | Persisted attempt to process one issue. | `execution` |
| `turn` | One Codex request/response exchange inside a run. | `step` |
| `worker` | Registered process host that claims and executes assignments. | `runner` |
| `workspace` | Per-issue filesystem directory used by an agent run. | `checkout` |
| `workflow` | Persisted project policy and profile configuration. | `pipeline` |

## Baseline lifecycle

The checked-in YAML list contains one sorted, exact current finding identity per row and no metadata.
It has no expiry or bypass. New findings, expanded aggregate locations, additions relative to the
merge base, stale rows, malformed schema, and unsynchronized deletion all fail. Removing a finding
and its row together passes. When no findings remain, the change must delete both the baseline file
and the checker's baseline read/compare branch, leaving the direct rules as one hard gate.

`scripts/check.sh` and `scripts/unit.sh` run `scripts/prepare_navigation_git_history.sh` before the
checker or its task test. Shallow CI checkouts are completed so `origin/main` and the real merge base
are available; failure to provide that Git history is a hard gate failure.
