---
name: handoff
description:
  Submit a valid implementation handoff when requesting the Ready to Merge
  state, including required completion evidence and blocker conventions.
---

# Implementation handoff

When an implementation requests `target_state: "Ready to Merge"`, the
top-level payload must include `comment` (a non-empty string), `result` (a
map), and `references` (a map). This requirement is conditional on that state.

## Required fields

| Field | Requirement |
| --- | --- |
| `comment` | Non-empty top-level completion summary. |
| `result` | Top-level map containing validation and outcome details; put blocker evidence in `result.blockers`. |
| `references` | Top-level map. Branch, commit, and other completion metadata are optional, but one complete PR pair below is required. |
| `references.pr_url` | `https://github.com/...` PR URL, paired with non-empty `references.pr_proof`. |
| `references.pr_proof` | Non-empty proof paired with `pr_url`. |
| `references.pull_request` | Alternative `https://github.com/...` PR URL, paired with non-empty `references.pull_request_completion_proof`. |
| `references.pull_request_completion_proof` | Non-empty proof paired with `pull_request`. |

Use either complete pair: `pr_url` + `pr_proof`, or `pull_request` +
`pull_request_completion_proof`. Incomplete pairs (missing URL/proof, empty
values, or non-GitHub URLs) are invalid. Do not mix keys across pairs; an
unpaired `pull_request` is invalid. General metadata such as `branch`, `commit`,
and completion evidence may also appear in `references`.

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
  },
  "target_state": "Ready to Merge"
}
```

## Failure and correction

| Validator field | Meaning | Correction |
| --- | --- | --- |
| `comment` | Required top-level completion comment is missing or empty. | Add a non-empty `comment`. |
| `result` | Required top-level result map is missing or not a map. | Add a map-valued `result`, including `blockers`. |
| `references` | Required top-level references map is missing or not a map. | Add a map-valued `references`. |
| `references.pr_url/pr_proof` | No complete accepted GitHub PR proof pair was supplied, including missing, empty, invalid, incomplete, or cross-pair fields. | Supply one complete pair above without mixing keys. |
