---
title: Codex 与 Linear 交互行为设计
genre: design
domain: [codex, linear]
status: current
language: zh-CN
updated: 2026-08-27
design_status: landed
---

# Codex 与 Linear 交互行为设计

本文维护 Symphony 中 Codex、Linear 和 GitHub PR handoff 的当前行为契约。核心原则是：
Codex 可以提出受控任务更新，但不接触 Linear API Key；实现完成时，Symphony 必须先确认精确
GitHub PR 已打开，最后才把 Linear issue 移到人工等待状态。

## 目标

- Codex 读取当前 task detail、recent comments 和 activity，并把最新人工评论作为最高优先级范围。
- Codex 可以追加评论、结构化结果、引用和受控状态请求。
- Linear token、GraphQL 文档和 Authorization header 只存在于 Symphony 后端。
- 实现完成由显式 `Ready to Merge` 请求触发，不由普通 turn exit 或 max-turn exhaustion 推断。
- 初次 PR 创建只有一个 owner：中心化 `AgentRunner`。
- GitHub/Linear automation 在 PR merge 后把 issue 移到 `Done`；Symphony 不执行 merge。

## 当前默认状态流

```text
Refining -> Needs Refinement Review -> Ready -> In Progress
  -> Ready to Merge -> Done
```

- 可调度状态：`Refining`、`Ready`、`In Progress`。
- 人工等待状态：`Needs Refinement Review`、`Ready to Merge`。
- `Ready to Merge` 没有 executable route，Orchestrator 不领取它。
- 人工提出实现修改时使用 `Ready to Merge -> In Progress`。Codex 更新同一 Linear
  `branchName` 和同一 PR，重新验证后再次请求 `Ready to Merge`。
- `Done` 是默认流唯一成功终态；`Canceled`、`Cancelled`、`Duplicate` 保持取消终态。

## 信任与所有权边界

Codex 只看到两个 task-scoped tools：

- `linear_task_read`：读取当前 issue detail 和可选的 recent activity。
- `linear_task_update`：请求更新当前 issue 的允许字段。

不暴露 raw GraphQL，不把 `LINEAR_API_KEY` 注入 Codex 环境，不允许操作其它 issue。profile 的
`allowed_updates` 和 `workflow.allowed_transitions` 同时约束请求。

实现交付的所有权如下：

- Codex：实现、测试、验证、commit，并 push 精确 Linear `branchName`；提交 final
  comment/result/references；显式请求 `Ready to Merge`。
- Symphony：校验 issue/repository/default/head，lookup-before-create，确保 open PR，记录 PR URL，
  然后执行 Linear 写入。
- Human/GitHub：review 和 merge。
- Linear GitHub integration：PR merged 后转到 `Done`。

## 默认 workflow policy

```yaml
tracker:
  active_states: ["Refining", "Ready", "In Progress"]
  terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]

workflow:
  states:
    Refining: {profile: refinement}
    Ready: {profile: implementation}
    In Progress: {profile: implementation}
  human_review_states: ["Needs Refinement Review", "Ready to Merge"]
  allowed_transitions:
    - {from: Refining, to: Needs Refinement Review, actor: codex, profile: refinement}
    - {from: Ready, to: In Progress, actor: codex, profile: implementation}
    - {from: In Progress, to: Ready to Merge, actor: codex, profile: implementation}
    - {from: Ready to Merge, to: In Progress, actor: human, profile: implementation}

profiles:
  implementation:
    executor: {type: codex_agent}
    allowed_updates:
      description: false
      comment: true
      result: true
      target_states: ["In Progress", "Ready to Merge"]
```

运行时 authority 是每个 enabled project 的 SQLite active workflow version。checked-in
`workflow.yml` / `profiles.yml` 只是 split package 示例和导入导出 artifact。

## 工具契约

### `linear_task_read`

实现 turn 开始时必须调用：

```json
{"include_activity": true, "activity_limit": 50}
```

返回当前 issue detail、comments 和 recent activity。最新明确人工评论覆盖更早 description；如果
两者冲突，Codex 在 workpad/comment 中记录解释后再编辑代码。

### `linear_task_update`

普通更新可以只包含 profile 允许的字段。实现完成请求必须同时包含：

```json
{
  "target_state": "Ready to Merge",
  "comment": "Completed: ...; Validation: ...; Deviations: None; Blockers: None",
  "result": {
    "completed": "...",
    "validation": "...",
    "deviations": "None",
    "blockers": "None"
  },
  "references": {
    "branch": "exact-linear-branch",
    "commit": "<sha>"
  }
}
```

缺少 comment/result/references、target 不允许、或没有 `AgentRunner` 注入的 handoff boundary
时，请求失败。

## 原子实现 handoff

收到显式完成请求后，顺序固定：

1. 校验 Linear identifier/title、精确 `branchName`、configured default branch、GitHub repository
   identity，以及 remote head branch 存在。
2. 对精确 repository/base/head 查找 open PR。
3. 已有 open PR 则复用；否则创建 title 包含 Linear identifier、body 包含精确
   `Fixes <ID>` 的 PR。
4. 添加 branch/PR reference，写 final comment/result。
5. 最后更新 Linear `In Progress -> Ready to Merge`。

任何 branch/GitHub/auth/PR 失败都会返回 typed error，并让 issue 留在 `In Progress`。Linear
transition 失败也必须可见；此时 PR 已存在，重试会 idempotently 复用。

GitHub 主路径从实际 Symphony service environment 查找 `gh`，使用非交互、timeout-bounded 命令。
如果 `gh` 不可用或不可用且存在 `GH_TOKEN` / `GITHUB_TOKEN`，使用现有 Req/proxy stack 的 REST
fallback。closed/merged branch PR 是冲突，不创建含义不清的 duplicate。命令输出、错误和日志必须
redact token。

handoff 只依赖配置的 repository identity 和 GitHub remote state，不依赖 Symphony host 上存在
worker workspace，因此本地与 SSH worker 使用相同边界。

## 审计与错误

- `implementation_handoff` 记录 `started`、`completed`、`failed` phase event。
- event 包含 issue identifier/id、session id、run id；completed event 包含 PR URL、repo、base、head。
- profile-policy rejection、GitHub typed error、Linear GraphQL/update failure和 persistence degradation
  都必须可见，不能静默转换成成功。
- attachment、comment 和 state update 仍写 task-tool audit；Linear state update 永远是 handoff 最后一步。

## Rollout 边界

应用代码不安装 Linear GitHub integration、不修改 team automation，也不 archive Linear state。
这些属于 operator rollout。安全顺序和现行操作清单由
[用户指南](user-guide.zh-CN.md)维护。

## 验收标准

- PR failure 时零 Linear completion writes。
- 重试已有 open PR 不 create duplicate。
- closed/merged PR、missing branch/auth、repository mismatch、CLI/API/Linear failure 都 typed 且可见。
- 普通 turn exit/max turns 不触发 handoff。
- `Ready to Merge` 不调度、不由 Symphony 移到 `Done`。
- Codex 环境、prompt、arguments、events 和日志不泄漏 Linear/GitHub token。
