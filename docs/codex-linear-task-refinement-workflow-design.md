---
title: Codex / Linear 任务细化工作流
genre: design
domain: [codex, linear]
status: current
language: zh-CN
updated: 2026-08-07
design_status: landed
---

# Codex / Linear 任务细化工作流

## 描述体积测量

成功请求进入 `Needs Refinement Review` 时，受限更新边界测量最终描述：本次提交了新描述
则使用新值，否则使用 issue 当前描述。字符数按 Unicode codepoint 计数；逻辑行数先把 CRLF
和裸 CR 规范化为 LF，空描述为零行。实际值等于有效阈值时不超限，任一维度严格超过阈值
时，仅在已有里程碑评论中追加一次简短的非阻断精简提示。

描述、状态和里程碑评论全部成功后，系统写入一条
`refinement.description_measurement` event。payload 包含 `characters`、`lines`、
`character_limit`、`line_limit`、`over_limit` 和规范化后的命中 `label_overrides`。
持久化失败沿用 event writer 的显式结构化日志与返回语义，但不回滚或阻断已经成功的 Linear
更新。

本文维护 `pull -> read -> update task detail -> comment -> transit` 这条工作流。它覆盖从 Linear 拉取候选 task，到 Codex 读取任务、细化需求、更新任务详情、评论说明并请求状态流转的行为契约。

## 目标

- 从 Linear 拉取可处理 task。
- Codex 获取当前 task 的最小必要信息。
- Codex 读取当前 task 的评论和状态变更，判断是否是新细化任务或打回返工任务。
- Codex 基于代码现状、需求描述和长期设计细化 task detail。
- 人在 Linear 中确认细化后的需求。
- Codex 不直接接触 Linear API Key。
- 所有 Linear 写操作由 Symphony 后端校验和执行。

## 适用阶段

主要适用于需求细化阶段：

```text
Backlog -> Todo -> Refining -> Needs Refinement Review -> Ready
```

其中：

- `Backlog`：想法或粗略任务，通常是一句话。
- `Todo`：等待 Symphony 调度的细化候选任务。
- `Refining`：Codex 正在细化任务。
- `Needs Refinement Review`：等待人确认细化结果。
- `Ready`：人已确认，任务可进入实现阶段。

该流程支持打回：

```text
Needs Refinement Review -> Refining
Ready -> Refining
```

打回时，最新人工评论是当前任务的主要输入。Codex 必须回应打回原因，而不是只基于旧 description 重新生成一版细化内容。

## 参与者

- Symphony Orchestrator：从 Linear 拉取候选任务，创建 run，调度 Codex。
- Codex：读取任务和仓库上下文，生成细化后的任务说明。
- Symphony Linear Tool Boundary：托管 Linear API Key，执行受限 Linear 操作。
- Human Reviewer：确认需求是否准确、完整、可开发。

## 状态入口

默认只有 `Todo` 是该流程的调度候选状态。Runner 在 Codex turn 开始前执行
`Todo -> Refining`，重新读取 Linear issue，并仅使用确认处于 `Refining` 的刷新结果继续执行。
`Refining` 是执行中状态，也是人工从 review 明确打回后再次细化时使用的状态，不属于默认
`tracker.active_states`。

进入条件：

- 新候选 task 的 Linear 状态是 `Todo`；人工打回任务的状态是 `Refining`。
- task 属于配置的 Linear project。
- task 没有被 terminal blocker 阻塞。
- 当前 worker/run 有权限处理该 task。

`Backlog -> Todo` 通常由人触发。Symphony 不应该自动把一句话想法从 `Backlog` 拉进 agent 执行，除非项目明确配置了这种自动化。

## 工具契约

该流程需要以下受限工具：

- `linear_task_read`
- `linear_task_update`

这些工具只能作用于当前 run 绑定的 issue。`linear_task_read` 必须一次返回 task detail、最近评论、状态变更和 refinement profile 的 allowed updates。`linear_task_update` 负责提交 description、comment 和目标状态，由后端按 refinement profile 做细粒度校验。

## 步骤

### 1. Pull

Symphony 从 Linear 拉取候选 task。

查询边界：

- 只查询配置 project。
- 只查询 active states 中适用于细化候选的 `Todo`，不把 `Needs Refinement Review` 当作候选。
- 只返回调度需要的字段，例如 id、identifier、title、state、priority、assignee、blocked_by、updated_at。

调度约束：

- 如果 task 已有 active run，不重复启动。
- 如果 task 状态不再 active，停止或跳过。
- 如果 task 移动到 human review 状态，不继续派发 Codex。

选中 `Todo` 后，Runner 必须先验证 workflow 允许 actor=`codex`、profile=`refinement` 的
`Todo -> Refining`，请求 Linear 更新状态，再重新读取 issue。转换被拒绝、未配置，或刷新结果不是
`Refining` 时，本次 run 显式失败且不得启动 Codex。

### 2. Read Detail And Comments

Codex 通过 `linear_task_read` 读取当前 task、最近评论和状态变更。读取 comments/activity 是强制步骤，不能拆成可选行为。

建议返回：

```json
{
  "issue": {
    "id": "linear issue id",
    "identifier": "MT-123",
    "title": "Short idea",
    "description": "Original task body",
    "url": "https://linear.app/...",
    "state": {
      "name": "Refining"
    },
    "labels": ["backend"],
    "blocked_by": []
  },
  "activity": {
    "comments": [
      {
        "id": "comment id",
        "author_type": "human",
        "body": "The scope is still too broad; split deployment docs from runtime behavior.",
        "created_at": "2026-05-06T08:00:00Z"
      }
    ],
    "state_changes": [
      {
        "from": "Needs Refinement Review",
        "to": "Refining",
        "changed_at": "2026-05-06T08:01:00Z"
      }
    ]
  },
  "workflow": {
    "current_profile": "refinement",
    "allowed_updates": {
      "description": true,
      "comment": true,
      "result": false,
      "target_states": ["Needs Refinement Review"]
    }
  }
}
```

Codex 不应获取：

- Linear API Key。
- raw Authorization header。
- 无关 issue 列表。
- 全量 workspace GraphQL 查询能力。

### 3. Analyze

Codex 在本地 workspace 中读取当前代码和设计文档，形成细化结果。

分析输入优先级：

1. 最新明确人工评论。
2. 最近状态变更，尤其是打回动作。
3. 当前 issue description。
4. Codex 上一次 `[codex]` 评论。
5. 代码和长期设计文档。

如果最新人工评论与 description 冲突，以最新人工评论为准，并在输出 comment 中说明采用了该评论作为当前指令。

细化结果应至少包含：

- 背景和问题。
- 明确目标。
- 非目标。
- 需要修改的模块或边界。
- 状态流转和人工确认点。
- 验收标准。
- 测试建议。
- 风险或未决问题。

如果信息不足，Codex 应留在当前 run 内补全 description。带有未决问题或显式占位符的产物不能进入
`Needs Refinement Review`。

打回返工时，细化结果还应包含：

- 本次打回原因摘要。
- 针对每条人工反馈的处理方式。
- 哪些 scope 或验收标准被新增、删除或收紧。

### 4. Update Task Detail

Codex 通过 `linear_task_update` 请求更新当前 issue description。该请求可以同时包含 comment 和 target state，但后端必须先完整校验再执行。

输入示例：

```json
{
  "description": "## Background\n...\n\n## Acceptance Criteria\n- ...",
  "references": {
    "latest_human_comment_id": "comment id or null"
  }
}
```

后端校验：

- issue 必须等于当前 run issue。
- 当前状态必须允许更新 detail，默认只允许 `Refining`。
- 如果 task 是从 review 状态打回，必须已经读取过评论或 activity，并在 tool request metadata 中带上参考的最新 comment id。
- description 长度在限制内。
- description 不包含 token、Authorization header 或本地 secret。
- 如果需要保留原始想法，应把原始内容放入 `Original request` 小节，而不是覆盖到不可追溯。

输出示例：

```json
{
  "success": true,
  "issue": {
    "id": "linear issue id",
    "identifier": "MT-123",
    "updated_at": "2026-05-06T08:00:00Z"
  }
}
```

### 5. Comment

Codex 通过 `linear_task_update` 追加说明。推荐与 description 更新合并在同一次请求中执行，减少半成功状态。

推荐 comment 内容：

```text
[codex] I refined this task into concrete scope and acceptance criteria.

Inputs used:
- Latest human comment: <comment id or none>

Please review the updated description. Open questions:
- ...
```

后端校验：

- 只能评论当前 issue。
- body 长度受限。
- 默认追加 `[codex]` 前缀。
- 不允许编辑或删除其它评论。

### 6. Transit

Codex 通过 `linear_task_update` 请求状态流转：

```text
Refining -> Needs Refinement Review
```

后端校验：

- 当前 issue 状态仍为 `Refining`。
- 目标状态存在于该 issue 所属 team workflow。
- transition 在 workflow allowlist 中。
- update detail 和 comment 至少一个已经成功，避免空转状态。
- 如果是打回返工，comment 必须明确回应打回原因。

#### Refinement description quality gate

仅当 profile 是 `refinement` 且规范化后的目标状态是 `Needs Refinement Review` 时，后端在任何
description/state 写入前检查同一请求中的候选 description。中间 description/comment 更新及其它
profile 不受影响。完成请求缺少非空 description 时也视为门禁失败，不读取 run 启动时的旧 description。

门禁按 Markdown ATX heading 切分章节并返回稳定顺序的完整、去重 violation 集合：

- `missing_required_section`：`Goal`、`Scope`、`Out of scope`、`Acceptance criteria`、
  `Validation` 任一章节不存在或为空；缺少候选 description 也使用此代码。
- `ambiguous_marker`：正文不区分大小写包含 `[NEEDS CLARIFICATION]`、`[TODO]`、`TODO:`、
  `TBD` 或 `???`。
- `unresolved_questions`：`Open questions`、`Unresolved questions` 或 `未决问题` 有非空内容，
  且去除 Markdown 列表前缀后不全是 `None` / `无`。
- `missing_testable_acceptance`：`Acceptance criteria` 中没有至少一个非空、且不含上述占位符的
  Markdown 有序或无序列表项。本规则只检查结构，不判断自然语言语义。
- `implicit_context_reference`：正文不区分大小写包含 `[CONTEXT REQUIRED]`。

失败时后端只创建一条诊断 comment，每项包含规则代码和修复提示；不执行候选 description 或状态
写入。comment 成功后 tool 返回同一 violation 集合的 typed quality-gate error，让 agent 可在当前 run
修正并重试。comment API 失败则返回 typed Linear error，不伪装成门禁通过。

如果 run 未修正并成功进入 review，Orchestrator 沿用唯一的 `no_progress_streak`：第一次完成但无状态
进展后仍为 `Refining`，连续第二次通过既有持久 `blocking_decision` 投递 `Blocked`。后续成功状态进展
按现有逻辑清零 streak 和 decision；门禁不拥有独立计数或阈值。

`Needs Refinement Review -> Ready` 必须由人执行。Symphony 不自动确认需求。

## 失败处理

推荐错误码：

- `issue_mismatch`
- `issue_not_active`
- `detail_too_long`
- `secret_detected`
- `transition_not_allowed`
- `target_state_not_found`
- `linear_request_failed`
- `linear_rate_limited`

处理原则：

- update detail 失败时，不进入 review 状态。
- comment 失败但 detail 成功时，可以重试 comment，不重复覆盖 detail。
- transition 失败时，保留 detail 和 comment，并在 run 事件中记录失败原因。
- Linear API 失败不应把 token 或 raw payload 写入日志。
- 如果无法读取评论或 activity，不应把打回任务当作普通新任务继续处理；应 comment 或记录 run event 请求人工介入。

## 审计

每次写操作记录：

- run id。
- issue id 和 identifier。
- tool name。
- actor：`codex`。
- 原状态和目标状态。
- 参考的最新人工 comment id。
- detail 是否更新。
- comment id。
- 校验结果。
- Linear API 结果。

禁止记录：

- Linear token。
- Authorization header。
- secret-bearing payload。

## 验收标准

- Codex 可读取当前 `Refining` task。
- `Todo` task 被选中后必须先转换并刷新为 `Refining`，Codex 不读取陈旧的 `Todo` 数据。
- Codex 可读取当前 task 的最近评论和状态变更。
- 人工打回后，Codex 根据最新人工评论调整 task detail。
- Codex 可更新当前 task detail。
- Codex 可追加当前 task comment。
- Codex 可请求 `Refining -> Needs Refinement Review`。
- Codex 不能移动其它 issue。
- Codex 不能跳过人工确认直接进入 `Ready`。
- Codex 不能在未读取评论的情况下处理打回任务。
- 执行 worker 使用现有的 `LINEAR_API_KEY`；Codex 对 Linear 的操作仍仅限 task-scoped tools。
- 所有写操作有审计事件。
