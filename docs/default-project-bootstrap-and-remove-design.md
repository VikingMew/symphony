---
title: Default Project 引导语义修正 + 手动移除 Project(252)
genre: design
domain: [workflow, projects, persistence, admin-ui]
status: current
language: zh-CN
updated: 2026-08-09
design_status: landed
---

# Default Project 引导语义修正 + 手动移除 Project

## 背景

移除 default-project dependency 的实现把 `default_project!` 改成纯查询,空库返回
`{:error, :not_found}`,**任何场景都不再自动创建**。这引入一个回归:第一次启动(零 project)
时系统直接进入 setup-required,必须手动去 Settings 建 project,没有任何引导。

用户明确的语义期望:

- **第一次启动(零 project)** → default 必须有:自动创建 `slug=default` 引导 project,
  导入默认 workflow.yml,系统能直接跑起来。
- **已有真实 project**(如 koroni / ccrr)→ default 无意义:不创建、不被引用、不参与解析。
- **不要自动清理**:移除 project(包括 default 残留)是显式用户操作 —— Settings/Projects
  给一个「移除 project」按钮即可,不做启动时自动删除的魔法行为。

## 现状

- `persistence/workflow_store.ex:20-27` `default_project!` 纯查询,无自动创建。
- `first_run_defaults.ex:37-43` 零 project 时直接 log "start in setup-required mode",
  不创建任何 project。
- `persistence.ex` / `linear/health.ex` / `admin_live/*` 仍有 `default_project` 引用
  (fallback 已改 first_enabled_project,但函数和概念还在)。
- Settings/Projects UI(settings/projects.ex)只有编辑和新增,没有移除功能。
- Persistence 层无 `delete_project/1`。
- FK:workflows → projects CASCADE；runs / issues / tasks → projects NO ACTION。

## 目标行为

1. **零 project 引导**:`default_project!` 在 `list_projects() == []` 时自动创建
   `%Project{name: "Default", slug: "default", default_branch: "main", enabled: true}`,
   并触发 first-run 默认 workflow 导入(恢复原有首启体验)。
2. **有真实 project 时**:`default_project!` 返回 `{:error, :not_found}`(现有行为),
   不创建、不参与解析。无显式 project context 的 runtime settings、候选查询和诊断返回
   `:missing_project_context`,不得回落到 Default 或 enabled projects 中的第一条记录。
3. **手动移除 project**:Settings/Projects 每个 project 卡片加「移除」按钮;
   `Persistence.delete_project/1` 删除 project 及其 CASCADE 的 workflow,
   关联的 runs/issues/tasks 的 project_id 置 NULL(历史记录保留,失去 project 归属),
   或显式返回错误(当 project 有活跃 workflow / 运行中任务时拒绝删除)。
4. **不允许移除最后激活状态的破坏性操作**:至少保留一个 enabled project 的约束由 UI
   校验(移除最后一个 enabled project 时提示),或允许(回到零 project 引导状态)。

## 设计决策

- **条件创建而非永久禁用**:守卫是「零 project」而不是「永远不」。这是与前一实现的唯一
  语义差异;解析链 / worker_queue / operator task 的显式化全部保留。
- **runtime 不猜测 project**:仅有 bootstrap Default 时保留首启运行体验;存在其他 project
  后,无上下文 runtime 读取显式失败。per-project polling 继续通过 workflow context 解析各自的
  Linear slug。
- **显式删除而非自动清理**:不做启动时检测删除 default 的魔法。用户要删 default,点按钮。
- **删除语义**：CASCADE workflows（project 移除 = 其 workflow 配置随之移除）；
  runs/issues/tasks.project_id SET NULL(审计历史保留但不绑定已删 project)。
- **移除按钮的确认**:phx-click + data-confirm,防误删。

## 涉及文件

- `lib/symphony_elixir/persistence/workflow_store.ex`(default_project! 条件创建)
- `lib/symphony_elixir/persistence.ex`(delete_project/1 委托 + 规格)
- `lib/symphony_elixir/persistence/project.ex`(如需要 on_replace / 级联配置)
- `lib/symphony_elixir_web/live/admin_live/settings/projects.ex`(移除按钮 + handle_event)
- `lib/symphony_elixir/first_run_defaults.ex`(零 project 自动创建后导入,可能需微调)
- 相关测试

## 不做

- 不做启动时自动清理 default 的逻辑。
- 不改 operator task / worker_queue / admin UI 已显式化的 project 解析。
- 不改 koroni / ccrr 数据。
