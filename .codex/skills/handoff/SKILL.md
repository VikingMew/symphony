---
name: handoff
description:
  Submit a valid implementation handoff when requesting the Ready to Merge
  state, including required completion evidence and blocker conventions.
---

# Implementation handoff

After validation, commit, push, and a successful `create_pull_request` call,
submit the completion payload by calling the `handoff` dynamic tool. The
top-level payload must include `comment` (a non-empty string), `result` (a
map), and `references` (a map).

An accepted `handoff` call captures the payload for the implementation worker;
it does not update Linear immediately. `Worker.Executor` requires that captured
payload before validation, runs the required gates, and only after they pass
writes the comment/result/references and `Ready to Merge` state through the
restricted Linear backend. Do not use `linear_task_update` as the implementation
completion action.

## Required fields

| Field | Requirement |
| --- | --- |
| `comment` | Non-empty top-level completion summary. |
| `result` | Top-level map containing validation and outcome details; put blocker evidence in `result.blockers`. |
| `references` | Top-level map containing every required reference below. |
| `references.branch` | Exact Linear implementation branch. |
| `references.commit` | Validated commit SHA. |
| `references.pr_url` | `https://github.com/...` PR URL returned by `create_pull_request`. |
| `references.pr_proof` | Non-empty completion proof returned with `pr_url`. |

Use the complete `pr_url` + `pr_proof` pair from the successful same-session
`create_pull_request` call. Missing, empty, mismatched, or non-GitHub PR
references are invalid.

When there are no blockers, set `result.blockers` to exactly `""`. Never use
`None`, `No blockers`, `None for handoff`, or any other free text as the
no-blocker value.

## Complete example

```json
{
  "comment": "Implemented the change and verified the full test suite.",
  "result": {"validation": "mix specs.check; make all", "blockers": ""},
  "references": {
    "branch": "feature/example",
    "commit": "abc1234",
    "pr_url": "https://github.com/acme/app/pull/42",
    "pr_proof": "PR is open and checks are green"
  }
}
```

## Failure and correction

| Validator field | Meaning | Correction |
| --- | --- | --- |
| `comment` | Required top-level completion comment is missing or empty. | Add a non-empty `comment`. |
| `result` | Required top-level result map is missing or not a map. | Add a map-valued `result`, including `blockers`. |
| `references` | Required top-level references map is missing or not a map. | Add a map-valued `references`. |
| `references.pr_url/pr_proof` | The same-session GitHub PR URL/proof pair is missing, empty, invalid, or mismatched. | Supply the pair returned by `create_pull_request`. |
