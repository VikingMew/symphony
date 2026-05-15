# Codex 与 Linear 交互行为设计

本文维护 Symphony 中 Codex agent 与 Linear task 交互的行为契约。目标是让 Codex 能读取任务、汇报进展、推动受控状态流转，同时不直接接触 Linear API Key，也不获得任意 Linear API 权限。

## 目标

- Codex 可以获取当前任务的必要上下文。
- Codex 可以读取当前任务的相关评论，并据此判断当前任务意图、人工打回原因和下一步动作。
- Codex 可以向当前任务追加受控评论。
- Codex 可以请求将当前任务推进到允许的下一个状态。
- Symphony 后端持有并使用 Linear API Key。
- Codex 子进程、prompt、tool arguments、日志和持久化事件中不出现 Linear API Key。
- 所有 Linear 写操作都有后端校验和审计记录。

## 非目标

- 不让 Codex 直接读取 `LINEAR_API_KEY`。
- 不暴露 raw GraphQL tool 给 Codex。
- 不允许 Codex 任意编辑历史评论、任意移动其它 issue、任意查询 Linear workspace。
- 不把 Linear API 细节作为 Codex prompt contract。
- 不在 workflow YAML 中保存明文 Linear token。

## 信任边界

Linear 官方 API 底层可以继续由 Symphony 后端通过 GraphQL 调用，但 GraphQL 文档、Authorization header 和 token 必须留在受信任的 Elixir/Phoenix/Orchestrator 边界内。

```text
Codex app-server
  -> 受限 dynamic tool 请求
  -> Symphony 后端校验 run / issue / state / payload
  -> Symphony Linear client 使用 token 调 Linear
  -> 返回最小必要结果给 Codex
```

Codex 只能提交结构化意图，不能提交任意 Linear GraphQL 文档。

## 当前状态

当前代码里存在 `linear_graphql` dynamic tool。它复用 Symphony 的 Linear 鉴权，让 Codex 可以发起 raw GraphQL 操作。

这个能力不应继续作为 Codex workflow tool。后续应移除 Codex 可见的 `linear_graphql`，并用下面的窄权限工具替代。Linear 诊断或管理员级操作应走 Symphony 后端/operator 内部路径，而不是通过 workflow 配置给 Codex 开一个 raw API 通道。

## 维护的工作流

- [Codex / Linear 任务细化工作流](codex_linear_task_refinement_workflow.zh-CN.md)：维护 `pull -> read -> update task detail -> comment -> transit`。
- [Codex / Linear 代码实现工作流](codex_linear_implementation_workflow.zh-CN.md)：维护 `pull -> worktree -> test -> code -> verify -> push to branch -> comment -> transit`。

## 需要修改的系统范围

按照本文设计，变化不只在 workflow package 或 `codex.command`。需要把 workflow contract、后端 policy、Codex prompt 和 dynamic tools 一起调整。

### Workflow package

split workflow package 由 `workflow.yml` 和 `profiles.yml` 组成；`profiles.yml` 同时包含
base prompt 和执行 profile。它是导入/导出格式，不是运行时 source。它的导入单位不是只包含
`workflow:` 节点的对象：`workflow` 定义流程路由和状态流转，顶层 `profiles` 定义可被 workflow
引用的执行 profile。

- 定义 state 到 profile 的路由，例如 `workflow.states.Refining.profile: refinement`。
- 在顶层 `profiles` 定义 profile 自身，例如 `refinement`、`implementation`、`merge`，每个 profile 必须有 `name`。
- 定义 human review states，例如 `Needs Refinement Review`、`Needs Implementation Review`。
- 定义 allowed transitions，包含 source state、target state、actor 和可选前置条件。
- 定义每个 profile 可用的 Linear update 能力，例如是否允许改 description、是否允许提交 result、允许转到哪些目标状态。

示意：

```yaml
workflow:
  states:
    Refining:
      profile: refinement
    Ready:
      profile: implementation
    In Progress:
      profile: implementation

  human_review_states:
    - "Needs Refinement Review"
    - "Needs Implementation Review"

  allowed_transitions:
    - from: "Refining"
      to: "Needs Refinement Review"
      actor: "codex"
      profile: "refinement"
    - from: "Needs Refinement Review"
      to: "Ready"
      actor: "human"
    - from: "Needs Refinement Review"
      to: "Refining"
      actor: "human"
    - from: "Ready"
      to: "In Progress"
      actor: "codex"
      profile: "implementation"
    - from: "In Progress"
      to: "Needs Implementation Review"
      actor: "codex"
      profile: "implementation"
    - from: "Needs Implementation Review"
      to: "Ready to Merge"
      actor: "human"
    - from: "Needs Implementation Review"
      to: "In Progress"
      actor: "human"

profiles:
  refinement:
    name: "Refinement"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Refine the task into clear requirements and acceptance criteria.
    allowed_updates:
      description: true
      comment: true
      result: false
      target_states: ["Needs Refinement Review"]

  implementation:
    name: "Implementation"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Implement, test, verify, and prepare the work for human review.
    allowed_updates:
      description: false
      comment: true
      result: true
      target_states: ["In Progress", "Needs Implementation Review"]
```

### `Config.Schema`

`Config.Schema` 需要解析并校验这些新字段：

- 顶层 profiles、profile `name` 和 executor/prompt/tool/update policy。
- review states。
- allowed transitions。
- 每个 profile 的 allowed updates。
- workflow schema 校验必须拒绝缺失 `workflow.states`、缺失顶层 profile `name`、以及把状态路由写在
  `profiles.<id>.active_states` 的配置。

Schema 校验应拒绝明显不安全配置，例如 Codex profile 允许从 review state 自动进入确认状态、或 target state 不在已声明 workflow 中。

### `Orchestrator`

Orchestrator 需要从“按 active state 直接派发”升级为“按 profile + activity 分类调度”：

```text
pull issue
read issue detail
read recent comments/activity
classify profile and current intent
dispatch matching prompt/tool policy
```

状态只决定阶段，不能单独决定任务意图。Orchestrator 必须把最近人工评论和状态变更纳入 run context，用于区分：

- 新细化任务。
- 细化打回返工。
- 新实现任务。
- 实现打回返工。
- merge 任务。

### `DynamicTool`

`DynamicTool` 需要移除默认暴露给 Codex 的 raw `linear_graphql`，改为暴露受限工具：

- `linear_task_read`
- `linear_task_update`

如需 Linear 诊断或管理员级操作，应走 Symphony 后端/operator 内部路径，不作为 Codex workflow tool，也不放进 workflow 配置开关。

后端 policy 必须在 tool 执行时校验：

- 当前 run 是否绑定该 issue。
- 当前 profile 是否允许该 update 字段。
- target state 是否在 allowed transitions 中。
- 打回任务是否已读取并引用最近人工评论。
- implementation transition 是否已有验证结果和 branch/result 信息。

### `Codex.AppServer`

Codex 子进程启动时需要收紧环境变量继承：

- 默认移除 `LINEAR_API_KEY`、`LINEAR_TOKEN`、tracker token 和其它外部服务 token。
- 只允许明确的 runtime env，例如 proxy 变量和 Codex 自身必需配置。
- 不再依赖 `shell_environment_policy.inherit=all` 来传递敏感环境。

### `PromptBuilder`

Prompt 需要按 profile 生成，而不是一个通用 prompt 覆盖所有阶段：

- refinement prompt：读取 detail/activity，细化需求，更新 description/comment，进入 `Needs Refinement Review`。
- implementation prompt：读取 detail/activity，准备 worktree，测试、实现、验证、推分支、comment，进入 `Needs Implementation Review`。
- merge prompt：只在 merge profile 中使用，处理受控 merge 和完成状态。

所有 prompt 都必须包含相同原则：

```text
Before acting, read the task detail and recent comments/activity.
If the task was returned from review, treat the latest human comment as the controlling instruction.
Do not transition forward unless you have addressed that feedback.
```

### docs / skills

repo-local `linear` skill 需要从 raw GraphQL 操作迁移到受限 tools：

- 默认使用 `linear_task_read` 读取任务上下文。
- 默认使用 `linear_task_update` 提交 description/comment/result/transition。
- 不再指导 Codex 通过 raw GraphQL 直接操作 Linear。

## 可打回流程原则

所有流程契约都必须支持被人打回。状态只表示任务所处阶段，不能单独定义当下任务意图。Codex 每次开始或恢复 run 时，必须读取 issue detail 和相关评论，综合判断当前要处理的是新任务、继续任务、修正任务还是被打回后的返工任务。

默认规则：

- 人可以从 review 状态打回到前一个 agent-work 状态，例如 `Needs Refinement Review -> Refining` 或 `Needs Implementation Review -> In Progress`。
- 人也可以把 `Ready` 打回 `Refining`，表示已确认需求需要重新细化。
- 人可以把 `Ready to Merge` 打回 `In Progress`，表示验收后仍发现实现问题。
- Codex 不能只根据 Linear state 自动假设任务已经准备好；必须读取最近人工评论、描述变更和自身上一条 `[codex]` 评论。
- 当评论和 description 冲突时，最近的明确人工评论优先；Codex 应在新评论中说明它采用了哪个指令。
- 打回后的 Codex 输出必须回应打回原因，而不是重新执行完整旧流程。

## 推荐工具

对 Codex 暴露的 Linear tools 应尽量少。细粒度权限留在 Symphony 后端做，不需要让 Codex 面对一组 `issue_get`、`activity_get`、`comment_create`、`transition` 小工具。

默认生产形态建议只暴露两个 tool：

- `linear_task_read`
- `linear_task_update`

### `linear_task_read`

一次返回当前 task 的完整可执行上下文，包括 issue detail、最近评论、状态变更和当前 profile 允许的动作。这个 tool 合并了“读取 task detail”和“读取 comments/activity”的能力，避免 Codex 忘记读评论。

输入：

```json
{
  "include_activity": true,
  "activity_limit": 20,
  "since": "optional ISO8601 timestamp"
}
```

约束：

- 只能读取当前 run 绑定的 issue。
- 默认必须包含最近评论和必要状态变更摘要。
- 返回当前 Codex profile，例如 `refinement`、`implementation` 或 `merge`。
- 返回后端已计算的 allowed actions，而不是让 Codex 查询全量 Linear workflow。
- 不返回 token、webhook secret、Authorization header、无关 issue 活动或全量 workspace GraphQL 能力。

建议输出字段：

```json
{
  "issue": {
    "id": "linear internal id",
    "identifier": "MT-123",
    "title": "Issue title",
    "description": "Issue description",
    "url": "https://linear.app/...",
    "state": {
      "id": "state id",
      "name": "In Progress",
      "type": "started"
    },
    "labels": ["backend"],
    "assignee": {
      "id": "user id",
      "name": "optional display name"
    },
    "blocked_by": [
      {
        "id": "issue id",
        "identifier": "MT-100",
        "state": "Done"
      }
    ]
  },
  "activity": {
    "comments": [
      {
        "id": "comment id",
        "author_type": "human",
        "body": "Please tighten the acceptance criteria around proxy env handling.",
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
    "current_profile": "implementation",
    "allowed_updates": {
      "description": false,
      "comment": true,
      "result": true,
      "target_states": ["Needs Implementation Review"]
    }
  }
}
```

### `linear_task_update`

提交 Codex 对当前 task 的受控更新。这个 tool 合并 description 更新、comment、结果汇报和状态流转。Codex 提交意图，Symphony 后端按当前 profile 做细粒度校验。

输入：

```json
{
  "description": "optional updated task detail",
  "comment": "optional comment body",
  "target_state": "optional target state",
  "result": {
    "branch": "optional branch name",
    "commit": "optional commit sha",
    "pr_url": "optional pull request url",
    "validation": [
      {
        "command": "mise exec -- mix test",
        "status": "passed"
      }
    ]
  },
  "references": {
    "latest_human_comment_id": "optional comment id used as instruction",
    "pr_url": "optional pull request URL to bind to the issue",
    "commit_url": "optional commit URL to bind to the issue",
    "branch_url": "optional branch URL to bind to the issue",
    "urls": ["optional additional HTTP(S) URLs to bind to the issue"]
  }
}
```

约束：

- 只能更新当前 run 绑定的 issue。
- 后端按当前 profile 决定允许字段：
  - `refinement`：允许 `description`、`comment`、`target_state = Needs Refinement Review`，不允许 `result`。
  - `implementation`：允许 `comment`、`result`、`target_state = Needs Implementation Review`，默认不允许改 `description`。
  - `merge`：允许 merge result、comment 和受控 terminal transition，默认不允许改需求 detail。
- 后端必须基于 workflow 状态机校验 `target_state`。
- 如果包含 `target_state`，后端应同时校验必要前置条件，例如已 comment、已更新 detail、已推送 branch 或已记录验证结果。
- 如果 task 是打回返工，必须引用或总结最近人工 comment。
- description、comment 和 result 中不得包含 token、Authorization header 或本地 secret。
- `references` 或 `result` 中的具体 HTTP(S) URL 会由 Symphony 后端绑定到当前 Linear
  issue；纯 branch 名、commit sha、comment id 等非 URL 元数据只保留在 comment/result
  里，不会被猜测成远端链接。

默认状态流转建议：

```text
Backlog
  -> Refining
  -> Needs Refinement Review
  -> Ready
  -> In Progress
  -> Needs Implementation Review
  -> Ready to Merge
  -> Merging
  -> Done
```

Codex 可请求的典型流转：

- `Refining -> Needs Refinement Review`
- `Ready -> In Progress`
- `In Progress -> Needs Implementation Review`
- `Ready to Merge -> Merging`

人工确认状态：

- `Needs Refinement Review`
- `Needs Implementation Review`

这些状态由人流转，Symphony 不应自动派发 agent。

返回示例：

```json
{
  "success": true,
  "issue": {
    "id": "linear issue id",
    "identifier": "MT-123",
    "state": "Needs Implementation Review"
  },
  "comment": {
    "id": "comment id",
    "url": "optional comment url"
  },
  "applied": {
    "description": false,
    "comment": true,
    "target_state": true,
    "result": true
  }
}
```

## Codex 环境变量策略

启动 Codex 子进程时，Symphony 应使用 allowlist，而不是继承全部环境变量。

默认允许：

- `HTTP_PROXY`
- `HTTPS_PROXY`
- `ALL_PROXY`
- `NO_PROXY`
- 小写 proxy aliases
- Codex 自身运行必需且不暴露外部系统 token 的变量

默认移除：

- `LINEAR_API_KEY`
- `LINEAR_TOKEN`
- tracker token
- GitHub、Linear、Slack 等外部服务 token，除非某个受控 worker profile 明确允许

如果需要给 Codex 访问 OpenAI/Codex 认证，应通过 Codex 自身认证文件或受控 runtime profile 处理，不应混入 Linear token。

## 审计

每次 Linear 写操作至少记录：

- `run_id`
- Linear issue id 和 identifier
- tool name
- actor 类型：`codex`
- 请求的目标状态或 comment id
- 校验结果
- Linear API 调用结果
- timestamp

禁止记录：

- Linear API Key
- Authorization header
- secret-bearing payload
- 完整 proxy URL 中的用户名密码

## 错误处理

后端应返回面向 agent 的稳定错误码和简短说明：

- `issue_mismatch`
- `transition_not_allowed`
- `target_state_not_found`
- `comment_too_long`
- `linear_auth_missing`
- `linear_request_failed`
- `linear_rate_limited`

错误响应可以包含下一步建议，但不能包含 token、raw Authorization header 或未脱敏请求。

## 迁移路径

1. 从 Codex 默认 dynamic tools 中移除 `linear_graphql`。
2. 新增 `linear_task_read`，一次返回 issue detail、comments/activity 和 allowed updates。
3. 新增 `linear_task_update`，由后端按 profile 校验 description/comment/result/transition。
4. Codex 启动环境改为敏感变量 denylist 或 allowlist。
5. 将 repo-local `linear` skill 从 raw GraphQL 操作迁移到 `linear_task_read` / `linear_task_update`。

## 验收标准

- Codex 进程环境中没有 `LINEAR_API_KEY`。
- Codex 无法调用 raw Linear GraphQL。
- Codex 可以通过 `linear_task_read` 读取当前任务的最小必要信息、相关评论和状态变更摘要。
- Codex 可以通过 `linear_task_update` 提交 comment、result、受控 description 更新和允许的状态流转。
- 人工打回后，Codex 会基于最近评论判断返工任务，而不是仅按状态重复旧流程。
- 对其它 issue 的读取、评论和状态变更会被拒绝。
- Linear 写操作均有审计事件。
- 日志和 dashboard 不暴露 token 或 Authorization header。
