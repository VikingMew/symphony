---
name: linear
description: |
  Use Symphony's restricted Linear task tools to read the current task,
  update task detail, add comments, and request workflow transitions.
---

# Linear Task Tools

Use this skill only inside a Symphony Codex app-server session where the
restricted task tools are injected. Do not use raw Linear GraphQL from Codex.
Symphony owns the Linear API key and enforces task scope and workflow policy.

## Tools

### `linear_task_read`

Read the current task and recent activity before deciding what to do.

Input:

```json
{
  "include_activity": true,
  "activity_limit": 50,
  "since": null
}
```

Use it at the start of every refinement, implementation, review-response, or
merge turn. Comments are part of the workflow contract: a human may have rejected
the previous result or changed scope in a comment before moving the state back.

### `linear_task_update`

Update the current task through Symphony's policy-checked task API.

Input:

```json
{
  "description": "optional replacement description",
  "comment": "optional concise task comment",
  "target_state": "optional workflow state",
  "result": {
    "optional": "structured verification or handoff details"
  },
  "references": {
    "optional": "branch, commit, PR, or artifact references"
  }
}
```

Only send fields that are needed. Symphony rejects fields and target states that
are not allowed by the current workflow profile.

## Workflow Use

### Refinement

1. Call `linear_task_read` with activity.
2. Read the current code, docs, and long-term design relevant to the idea.
3. Produce a refined task with problem statement, scope, acceptance criteria,
   validation plan, risks, and explicit out-of-scope items.
4. Call `linear_task_update` with the refined description or workpad comment.
5. Request `target_state: "Needs Refinement Review"` when ready for human review.

If a human moved the task back to `Refining`, read comments first and address the
rejection before updating the task again.

### Implementation

1. Call `linear_task_read` with activity.
2. Treat comments as authoritative review feedback.
3. Pull/sync, prepare the worktree, implement, test, verify, push the branch, and
   attach references through the allowed project workflow.
4. Call `linear_task_update` with a concise comment, structured `result`, and
   relevant `references`.
5. Request `target_state: "Needs Implementation Review"` only when validation and
   handoff are complete.

If a human moved the task back to `Ready` or `In Progress`, read comments first
and address the requested changes before continuing.

### Merge

1. Call `linear_task_read` with activity.
2. Follow the repository `land` skill and merge policy.
3. Call `linear_task_update` with merge result and references.
4. Request `target_state: "Done"` only after the merge is complete.

## Guardrails

- Do not ask the operator for a Linear API key.
- Do not request or expose raw Linear GraphQL access from Codex.
- Do not update task state without first reading recent comments.
- Do not modify human review states directly; humans move review states forward
  or back.
- Use one concise comment/update per workflow milestone instead of extra
  top-level status noise.
