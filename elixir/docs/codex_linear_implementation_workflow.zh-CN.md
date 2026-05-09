# Codex / Linear 代码实现工作流

本文维护 `pull -> worktree -> test -> code -> verify -> push to branch -> comment -> transit` 这条工作流。它覆盖已确认需求从 Linear 进入实现阶段后，Codex 如何准备 workspace、执行测试、修改代码、验证结果、推送分支、评论并请求状态流转。

## 目标

- 从 Linear 拉取已确认、可开发的 task。
- Codex 读取 task detail、最近评论和状态变更，判断当前是新实现、继续实现还是打回返工。
- 为 task 准备隔离 workspace/worktree。
- Codex 基于 task detail 实现代码变更。
- Codex 执行必要测试和验证。
- Codex 将代码推送到可审查分支。
- Codex 在 Linear comment 中汇报结果。
- Codex 请求进入人工实现验收状态。

## 非目标

- 不让 Codex 持有 Linear API Key。
- 不让 Codex 任意操作 Linear issue。
- 不自动代表人完成实现验收。
- 不自动合并 main，除非任务处于明确的 merge 阶段且策略允许。
- 不跳过测试或验证直接推状态。

## 适用阶段

主要适用于实现阶段：

```text
Ready -> In Progress -> Needs Implementation Review -> Ready to Merge -> Merging -> Done
```

其中：

- `Ready`：需求已由人确认，可开始实现。
- `In Progress`：Codex 正在实现和验证。
- `Needs Implementation Review`：等待人验收实现。
- `Ready to Merge`：人已验收，准备合并。
- `Merging`：Codex 或受控自动化执行合并流程。
- `Done`：任务完成。

本文重点维护：

```text
Ready -> In Progress -> Needs Implementation Review
```

`Needs Implementation Review -> Ready to Merge` 由人触发。`Ready to Merge -> Merging -> Done` 可由后续 merge 工作流维护。

该流程支持打回：

```text
Needs Implementation Review -> In Progress
Ready to Merge -> In Progress
```

打回时，最新人工评论是当前实现任务的主要输入。Codex 必须优先处理打回反馈，而不是仅按旧 task detail 重跑实现流程。

## 参与者

- Symphony Orchestrator：拉取候选 task，创建 run，分配 workspace。
- Workspace Manager：准备 task 对应 worktree 或 workspace。
- Codex：实现代码、运行验证、生成结果说明。
- Git Remote：接收 feature branch。
- Symphony Linear Tool Boundary：受限评论和状态流转。
- Human Reviewer：验收实现和决定是否进入 merge。

## 状态入口

默认 `Ready` 和 `In Progress` 可参与实现工作流。

推荐入口策略：

- 人把 task 从 `Needs Refinement Review` 移到 `Ready`。
- Symphony 发现 `Ready` 后，可以将 task 派给 Codex。
- Symphony 完成 workspace/bootstrap 并成功启动 Codex session 后，由 Symphony 后端执行
  `Ready -> In Progress`；该流转成功后才发送第一轮 Codex task prompt。
- workspace/bootstrap 失败或 Codex session 启动失败时，不应把 task 移到 `In Progress`。

如果 task 已经是 `In Progress`，Symphony 可以恢复或继续已有 run，但必须避免并发重复实现。

## 工具契约

Linear 侧需要以下受限工具：

- `linear_task_read`
- `linear_task_update`

`linear_task_read` 必须一次返回 task detail、最近评论、状态变更和 implementation profile 的 allowed updates。`linear_task_update` 负责提交 comment、result 和目标状态，由后端按 implementation profile 做细粒度校验。

Git / workspace 侧可以由 Codex 本地工具执行，但仍应受 workspace sandbox 和 hook 策略约束。

## 步骤

### 1. Pull

Symphony 从 Linear 拉取可实现 task。

查询边界：

- project 必须匹配配置。
- state 在实现入口状态中，例如 `Ready` 或 `In Progress`。
- blocker 必须满足项目策略。
- assignee/routing 必须匹配当前 worker。

调度约束：

- 一个 issue 同时只能有一个 active implementation run。
- 如果 issue 移动到 human review 状态，停止继续派发 Codex。
- 如果 issue 移动到 terminal 状态，停止 run 并清理可清理 workspace。

### 2. Read Detail And Comments

Codex 通过 `linear_task_read` 读取当前 task detail、最近评论和状态变更。

读取 activity 是强制步骤。实现任务可能被人打回到 `In Progress`，此时 description 可能仍然描述原始需求，而最近人工评论才说明当前必须修复的问题。`linear_task_read` 必须把这些信息合并返回，避免 Codex 只读 description 后误判任务。

分析输入优先级：

1. 最新明确人工评论，尤其是打回原因。
2. 最近状态变更，例如 `Needs Implementation Review -> In Progress`。
3. 当前 issue description。
4. PR review 或 branch/commit 信息，如果已经记录在评论或 Linear issue
   attachment 中。
5. Codex 上一次 `[codex]` 评论。
6. 当前 worktree diff 和测试结果。

如果评论和 description 冲突，以最新人工评论为准，并在最终 comment 中说明采用了哪条反馈。

### 3. Worktree

Workspace Manager 为 issue 准备独立 workspace 或 git worktree。

推荐规则：

- workspace 路径由 issue identifier 派生，稳定且可审计。
- 不删除用户未提交改动。
- 创建或复用 feature branch。
- branch 名优先使用 Linear `branchName`，否则使用规范化 fallback，例如 `codex/MT-123-short-title`。
- 执行 configured `after_create` / `before_run` hooks。

进入 Codex 前，workspace 应满足：

- 位于允许的 workspace root 内。
- 不是 symlink escape。
- git remote 可用。
- 基础依赖已按项目策略安装或可安装。

### 4. Test Baseline

Codex 在修改代码前应尽量获取 baseline。

推荐行为：

- 读取 README、测试命令、mise 配置和项目脚本。
- 运行轻量 smoke test 或相关测试。
- 如果 baseline 已失败，记录失败并判断是否与当前 task 相关。
- 不因为无关 baseline failure 直接停止，但必须在最终 comment 中说明。

### 5. Code

Codex 按 task detail 实现最小必要变更。

约束：

- 保持改动和 task scope 对齐。
- 不进行无关重构。
- 不修改 secret、凭证、本地环境文件。
- 不覆盖用户已有未提交改动。
- 对状态机、权限、外部 API、持久化 schema 等高风险变更补测试。
- 如果是打回返工，只修改与打回评论相关的范围，除非发现必须一起修复的直接依赖问题。

### 6. Verify

Codex 完成代码后运行验证。

推荐验证顺序：

```text
format -> compile/lint -> targeted tests -> full tests -> coverage when required
```

具体命令由项目决定，例如：

```bash
mise exec -- mix format
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix test --cover
```

验证结果必须记录：

- 执行了哪些命令。
- 哪些命令通过。
- 哪些命令失败以及失败原因。
- 是否存在未运行的验证，以及原因。
- 如果是打回返工，说明哪些验证覆盖了打回反馈。

### 7. Push To Branch

验证通过或达到可审查状态后，Codex 推送 feature branch。

推荐规则：

- 只推当前 task branch。
- 不直接推 `main`。
- 不强推，除非明确配置且 run 拥有该权限。
- 如果 remote moved，先按项目策略 pull/merge/revalidate。
- push 后记录 branch name、commit sha、remote URL 或 PR URL。`linear_task_update`
  中的具体 HTTP(S) URL 会由 Symphony 后端绑定到当前 Linear issue；没有 URL 的
  branch name 或 commit sha 仍只作为结果元数据记录。

如果项目使用 PR：

- 可以创建或更新 PR。
- PR body 应引用 Linear issue。
- PR 状态应写入 Linear comment。

### 8. Comment

Codex 通过 `linear_task_update` 在当前 task 追加结果说明。推荐把 comment、result 和目标状态合并在同一次请求中提交，由后端先完整校验再执行。

推荐 comment 模板：

```text
[codex] Implementation ready for review.

Branch: <branch>
Commit: <sha>
PR: <url if any>
Latest human feedback handled: <comment id or none>

Validation:
- <command>: passed
- <command>: passed

Notes:
- <important caveat or skipped verification>
```

后端校验：

- 只能评论当前 issue。
- body 长度受限。
- 默认追加 `[codex]` 前缀。
- 不记录 secret。
- 如果 task 是打回返工，comment 必须引用或总结最新人工反馈。

### 9. Transit

实现验证完成后，Codex 通过 `linear_task_update` 请求状态流转：

```text
In Progress -> Needs Implementation Review
```

`Ready -> In Progress` 是 Symphony 后端在 Codex session 启动成功后执行的入口流转，
不应由 Codex 自己通过 `linear_task_update` 请求。

后端校验：

- 当前 issue 等于 run issue。
- 当前状态仍在允许源状态。
- 目标状态存在。
- branch 已推送或明确记录了不能推送的原因。
- 验证结果已记录。
- transition 在 workflow allowlist 中。
- 如果是打回返工，comment 必须明确说明反馈已处理。

人确认后执行：

```text
Needs Implementation Review -> Ready to Merge
```

Codex 不应自动执行这个确认动作。

## 失败处理

推荐错误码：

- `workspace_prepare_failed`
- `baseline_failed`
- `verification_failed`
- `push_failed`
- `issue_mismatch`
- `transition_not_allowed`
- `target_state_not_found`
- `comment_too_long`
- `linear_request_failed`

处理原则：

- workspace 准备失败：不进入 `In Progress`，或如果已进入则 comment 说明并保持状态等待人工处理。
- 测试失败：保留分支和改动，comment 说明失败命令，不进入 `Needs Implementation Review`，除非项目允许“带失败验收”。
- push 失败：不进入 review 状态，comment 或 run event 记录失败原因。
- comment 失败：不阻塞本地结果保存，但不应静默转状态。
- transition 失败：保留 comment 和 branch，run 标记为需要人工处理。
- 如果无法读取评论或 activity，不应把打回任务当作普通实现继续处理；应 comment 或记录 run event 请求人工介入。

## 审计

每次实现 run 至少记录：

- run id。
- issue id 和 identifier。
- workspace path。
- branch name。
- commit sha。
- 验证命令和结果摘要。
- 参考的最新人工 comment id。
- comment id。
- source state 和 target state。
- push 结果。
- transition 结果。

禁止记录：

- Linear token。
- Git credentials。
- Authorization header。
- secret-bearing command output。

## 验收标准

- Codex 可以从 `Ready` task 开始实现。
- Codex 可以读取当前 task 的最近评论和状态变更。
- 人工打回后，Codex 根据最新人工评论限定返工范围。
- Workspace/worktree 路径受控且不逃逸 workspace root。
- Codex 可以运行测试并记录验证结果。
- Codex 可以推送 feature branch。
- Codex 可以评论当前 Linear task。
- Codex 可以请求 `In Progress -> Needs Implementation Review`。
- Codex 不能自动执行 `Needs Implementation Review -> Ready to Merge`。
- Codex 不能直接持有 Linear API Key。
- Codex 不能在未读取评论的情况下处理打回任务。
- 失败路径不会静默推进状态。
