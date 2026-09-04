---
title: Codex / Linear 代码实现工作流
genre: design
domain: [codex, linear]
status: current
language: zh-CN
updated: 2026-08-27
design_status: landed
---

# Codex / Linear 代码实现工作流

本文维护当前 `read -> workspace -> baseline -> code -> verify -> commit -> push -> explicit
handoff` 实现流。它适用于中心化 `AgentRunner` 的本地或 SSH-host Codex execution。

## 目标与非目标

目标：

- 使用 Linear 指定的精确 `branchName` 完成实现、验证、commit 和 push。
- 让最新人工 comment/activity 控制返工范围。
- 通过 final comment/result/references 显式请求 `Ready to Merge`。
- 由 Symphony idempotently 创建或复用 GitHub PR 后再更新 Linear。

非目标：

- Codex 不负责初次 PR 创建，也不在 PR 创建前等待 review/checks。
- Symphony/Codex 不 approve 或 merge PR，不 push `HEAD` 到 default branch。
- 普通 Codex exit、max-turn exhaustion 和测试通过本身都不是完成信号。
- 不自动迁移旧状态中的运行中 issue。

## 状态入口和出口

```text
Ready -> In Progress -> Ready to Merge
                       | human changes requested
                       v
                    In Progress -> Ready to Merge
```

`Ready` dispatch 后，Symphony 在 Codex work 开始时转到 `In Progress`。实现 turn 只在 Codex
显式调用 `linear_task_update(target_state: "Ready to Merge", ...)` 时尝试完成 handoff。
`Ready to Merge` 是人工等待状态，无 executable route。PR merge 后由 Linear automation 转到
`Done`。

## 实现步骤

### 1. 读取任务与人工反馈

在修改代码前调用 `linear_task_read(include_activity: true)`。读取 description、identifier、title、
`branchName`、comments 和 state changes。最新明确人工评论高于更早 description；冲突解释写进
workpad/comment。

### 2. 准备 workspace 和精确分支

Symphony 创建隔离 workspace，并校验/checkout Linear `branchName`。不得生成不同 task branch。
每次 run 可能重建 workspace，因此有价值的进度必须 commit/push，不能只留在本地目录。

SSH execution 中 workspace 只存在于 worker；后续 PR handoff 不得要求 Symphony host 能访问该路径。

### 3. Baseline、实现和验证

先运行与改动相关的 baseline/targeted checks，再做最小实现。遵循 repository `AGENTS.md`、spec、
格式、静态检查和测试约束。验证强度与风险相称；失败命令和原因进入 final result。

### 4. Commit 和 push

确认 branch 等于 Linear `branchName`，review diff，创建有意义的 commit，并 push 同一 branch。
worker host 需要 Git remote push auth。禁止把 feature result push 到 configured default branch。

### 5. 提交显式完成请求

Codex 的 `linear_task_update` 必须包含：

- `comment`：`Completed`、`Validation`、`Deviations`、`Blockers`。
- `result`：同样四类结构化信息。
- `references`：至少 branch、commit 和 `create_pull_request` 返回的 PR URL/completion proof。
- `target_state: Ready to Merge`。

初次实现不直接调用 `gh pr create`。Codex 按 [PR body contract](pull-request-body.md) 写 title/body
并调用受限 `create_pull_request`；`AgentRunner` 提供 backend-owned lookup/create boundary。

### 6. Symphony 原子 handoff

`AgentRunner` backend 校验 identifier、branch/default/repository、remote branch，lookup exact PR，必要时
create。Codex 再把返回的 PR reference、comment/result 写入 Linear，最后更新 state。PR 必须：

- repository 与配置/实际 remote identity 一致；
- base 是 `project.default_branch`；
- head 是精确 Linear `branchName`；
- title 包含 Linear identifier；
- body 包含精确 `Fixes <ID>`。

重复请求遇到 open PR 返回同一 URL。closed/merged PR 是 typed conflict。GitHub 失败时不执行任何
Linear completion write。

### 7. 人工 review 和返工

人只在 GitHub review/merge。需要修改时，把 Linear 从 `Ready to Merge` 移回 `In Progress` 并留下
comment。下一轮 Codex 读取该 activity，更新同一 branch/PR，重新验证、commit、push，再次显式请求
`Ready to Merge`。`create_pull_request` lookup 到同一 open PR 并复用且不覆盖人工正文；新建 PR
正文由 Codex 按 [PR body contract](pull-request-body.md) 提交。

## Failure Matrix

| Failure | Required behavior |
| --- | --- |
| Invalid/missing Linear branch | Typed failure; issue stays `In Progress` |
| Repository identity mismatch | Do not contact/create in a different repo |
| Remote branch missing | Do not create PR or update Linear completion |
| `gh` unavailable/unusable | Use REST only when environment token exists |
| No GitHub auth | Typed visible failure; no Linear completion writes |
| Existing closed/merged PR | Typed conflict; no duplicate PR |
| PR create race | Re-read exact tuple and reuse the open PR |
| Linear comment/state failure | Visible typed failure; retry reuses existing PR |
| Normal turn exit/max turns | Return control; no PR and no completion transition |

## 审计与验收

- phase event 证明 `PR started/completed` 发生在 Linear state transition 前，并携带 issue/session/run。
- test 证明 local/SSH workspace path 不参与 PR resolution。
- test 证明 open PR idempotency、REST fallback、redaction 和错误类型。
- dispatch/config test 证明 active states 只有 `Todo`、`Ready`、`In Progress`。
- repository audit 证明 runtime 不存在 backend feature merge 或 default-branch push 路径。
