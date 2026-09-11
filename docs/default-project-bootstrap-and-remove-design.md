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

移除 default-project dependency 后,Default 不再是可派发配置的隐式前提。空库仍需要一个
Settings 可见的引导入口,但该入口必须是 disabled placeholder,不能在缺少 repository URL
时进入 runtime dispatch。

用户明确的语义期望:

- **第一次启动(零 project)** → default 可作为 disabled 引导 project 出现,帮助用户进入
  Settings 配置真实 project 或补齐该 Default；补齐前系统保持 setup-required。
- **已有真实 project**(如 koroni / ccrr)→ default 无意义:不创建、不被引用、不参与解析。
- **不要自动清理**:移除 project(包括 default 残留)是显式用户操作 —— Settings/Projects
  给一个「移除 project」按钮即可,不做启动时自动删除的魔法行为。

## 现状

- `persistence/workflow_store.ex:20-47` `default_project!` 仅在 projects 表为空时创建
  disabled Default placeholder。
- `first_run_defaults.ex:37-43` 零 enabled project 时直接 log "start in setup-required mode",
  不导入 workflow。
- `persistence.ex` / `linear/health.ex` / `admin_live/*` 仍有 `default_project` 引用
  (runtime no-context fallback 已收敛为 configured Default / exactly one / missing context,但函数和概念还在)。
- Settings/Projects UI(settings/projects.ex)只有编辑和新增,没有移除功能。
- Persistence 层无 `delete_project/1`。
- FK:workflows → projects CASCADE；runs / issues / tasks → projects NO ACTION。

## 目标行为

1. **零 project 引导**:`default_project!` 在 `list_projects() == []` 时自动创建
   `%Project{name: "Default", slug: "default", default_branch: "main", enabled: false}`。
   该记录是 Settings 可见的引导占位,不参与 runtime dispatch；first-run 默认 workflow
   导入仍要求存在 enabled project。
2. **有真实 project 时**:`default_project!` 返回 `{:error, :not_found}`(现有行为),
   不创建新的 Default。无显式 project context 的 runtime settings 和诊断选择已配置的
   Default workflow；没有可用 Default 时,只有恰好一个 enabled 且已加载 workflow 的真实
   project 可以被解析。多项目无配置完整 Default 返回 `:missing_project_context`,不得按名称或插入顺序猜测。未配置仓库地址的 `slug=default` 占位记录即使旧数据中仍为 enabled,也不参与解析。
3. **手动移除 project**:Settings/Projects 每个 project 卡片加「移除」按钮;
   `Persistence.delete_project/1` 删除 project 及其 CASCADE 的 workflow,
   关联的 runs/issues/tasks 的 project_id 置 NULL(历史记录保留,失去 project 归属),
   或显式返回错误(当 project 有活跃 workflow / 运行中任务时拒绝删除)。
4. **不允许移除最后激活状态的破坏性操作**:至少保留一个 enabled project 的约束由 UI
   校验(移除最后一个 enabled project 时提示),或允许(回到零 project 引导状态)。

## 设计决策

- **条件创建而非永久禁用**:守卫是「零 project」而不是「永远不」。这是与前一实现的唯一
  语义差异;解析链 / worker_queue / operator task 的显式化全部保留。
- **runtime 只选择可派发 workflow**:未配置仓库地址的 bootstrap Default 不进入发布快照；
  无上下文 runtime 读取优先配置完整的 Default,否则只有恰好一个 enabled 且已加载 workflow 的
  project 时才解析成功；多项目无配置完整 Default 返回 `:missing_project_context`。per-project polling 继续通过 workflow context 解析各自的 Linear slug。
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
