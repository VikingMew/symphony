---
title: Agent-Facing Code O Conformance
genre: reference
domain: [observability, logging, errors]
status: current
language: en
owner: SymphonyElixir.ObservabilityCheck
updated: 2026-10-08
---

# Agent-facing code O conformance

The audit was reproduced at `337aef3` before remediation: 147 Logger calls across 21 `lib` files,
54 rescue/catch syntax sites, 17 message/reason classification branches in `LinearToolAudit`, and
zero `tool_call_id`/`callId` references under `lib`. The first source-check run produced 175
reviewed findings: 146 Logger metadata findings and 29 silent/default-success branches. Remediation
removed five entries. The checked-in checker output is the authoritative current waterline.

| Clause | Final status | Reproducible evidence |
| --- | --- | --- |
| O-01 | Partially satisfied | `mix test test/symphony_elixir/log_file_test.exs` parses the formatter and rotating file as JSON Lines and filters by fields. Explicit event metadata remains in the baseline. |
| O-02 | Partially satisfied | [logging.md](logging.md) is the canonical field table; the formatter emits one name per registered fact. Legacy calls without explicit registered metadata remain baselined. |
| O-03 | Partially satisfied | Remediated log-handler and tool-audit failures carry operation, location, offending value, expected shape, code, retryability, and applicable correlation. Remaining warning/error metadata debt is exact-listed. |
| O-04 | Satisfied | Dynamic-tool and public HTTP errors carry stable code/retryable values; `LinearToolAudit` copies typed fields and has no message/reason classifier. The wording-independence test is in `dynamic_tool_test.exs`. |
| O-05 | Partially satisfied | `mix observability.check` rejects unlisted silent capture and stale debt. Remaining reviewed branches are exact-listed in the one deletion-only baseline. |
| O-06 | Satisfied | Tool handler, centralized audit, worker forwarding, and run-history tests preserve `params.callId` as `tool_call_id` with issue/run/session correlation. |
| O-07 | Satisfied | [logging.md](logging.md#canonical-operator-commands) contains exactly one logs, trace, and metrics/state command with prerequisites. |
| O-08 | Satisfied | `LinearToolAudit`, worker summaries, analytics, and token accounting retain `duration_ms` and token/budget aggregation without new configuration or storage. |

Final totals are 4 satisfied, 4 partially satisfied, 0 not satisfied, and 0 not applicable. A full
8/0/0/0 claim is prohibited until `mix observability.check` reports a zero waterline and the
baseline mechanism is deleted.

## Commands

```bash
git grep -o 'Logger\.' 337aef3 -- lib | wc -l
git grep -l 'Logger\.' 337aef3 -- lib | wc -l
git grep -n -E '\brescue\b|\bcatch\b' 337aef3 -- lib | wc -l
git show 337aef3:lib/symphony_elixir/codex/linear_tool_audit.ex | sed -n '120,180p' | rg -o 'contains\?' | wc -l
git grep -n -E 'tool_call_id|callId' 337aef3 -- lib | wc -l
mix observability.check
```
