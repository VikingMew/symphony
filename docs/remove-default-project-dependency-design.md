---
title: 去除 Default Project 强制依赖设计(Multi-Project First)
genre: design
domain: [workflow, projects, persistence]
status: current
language: zh-CN
updated: 2026-08-09
design_status: landed
---

# 去除 Default Project 强制依赖设计

## 1. 背景

Symphony 曾存在一个「default project」的隐式强制依赖:只要数据库里没有 `slug="default"` 的 Project 记录,任何调用 `default_project()` 的地方都会**自动创建**一个 `{name: "Default", slug: "default", default_branch: "main", enabled: true}` 记录。当前运行库(`symphony.db`)里那个 `slug=default` 的 Default 记录就是这么来的；当前实现只允许空表引导创建 disabled 占位。

这带来三个问题:

1. **设计不需要它**:Symphony 的设计是多 project 并行(Koroni、ccrr 等真实 project 各自有自己的 workflow),不存在「默认 project」的概念,却被迫存在一个自动创建的魔法记录。
2. **隐式行为掩盖配置错误**:自动创建导致「未配置任何 project」和「已配置但缺 default」无法区分——系统永远看起来有 default,真实配置状态被掩盖。
3. **单 project 时代的遗留**：无参 `current_workflow()`、`current()` 的默认解析、worker_queue 的 project 兜底、first_run 导入目标，全部硬编码依赖 default project，与多 project 设计冲突。

## 2. 目标

把「隐式自动创建的 default project」改为「显式 project 上下文」:

- `default_project()` 不再自动创建记录,不存在就返回 `{:error, :not_found}`,由上层显式处理;
- 无参 `current_workflow()` 按「显式配置完整的 enabled `slug=default` workflow → 恰好唯一 enabled 且已加载 workflow 的非占位 project → `:missing_project_context` / setup_required」解析，不依赖自动创建的记录；
- 若空表引导路径创建 `slug=default` 占位,该记录必须是 disabled,且缺少 `repository_url`
  的 Default 占位即使旧数据中仍为 enabled,也不得发布为 runtime workflow；
- worker_queue 的 task 必须显式带 project_id,不带就报错;
- first_run 导入目标显式化,不再硬编码 default;
- 存量 `slug=default` 记录清理,真实 project(Koroni、ccrr)成为唯一事实来源。

## 3. 现状分析

### 3.1 强制依赖点

| 位置 | 行为 | 依赖 |
| --- | --- | --- |
| `Persistence.WorkflowStore.default_project!/0` (persistence/workflow_store.ex:20-34) | 查 `slug="default"`,没有就 insert | **自动创建(根因)** |
| `Persistence.WorkflowStore.current_workflow/0` | 无参版先 `default_project()` 再查 | 无参调用需要 default |
| `WorkflowStore.load_database_workflows` (workflow_store.ex:221-230) | 加载全部 enabled projects 的 workflow,`default_project_id` 优先配置完整 default；否则只接受唯一 loaded workflow | default 优先且禁止多项目猜测 |
| `WorkflowStore.default_project_id/2` (workflow_store.ex:272-277) | default 在 workflows 里就用它的 id；否则只有一个 loaded workflow 时使用该 id | default 优先且多项目缺上下文 |
| `Persistence.WorkerQueue.enqueue_task/1` (worker_queue.ex:79) | task 不带 project 就 `Map.put_new(:project_id, default.id)` | **静默兜底** |
| `FirstRunDefaults.import_if_needed` (first_run_defaults.ex:82) | 导入默认 workflow 必须 `default_project()` | 导入目标硬编码 |
| `HealthController.workflow_state/1` | `current_workflow()` 无参判断 setup 状态 | 无参调用 |
| `Orchestrator.current_workflow_record/1` | 按 workflow context 的 project id 解析 current workflow | 无参调用 |
| `AdminLive.State` / `WorkflowState` | admin 界面 selected_project 默认 default | UI 默认值 |
| `Linear.Diagnostics` | setup 检查项要求 default project 有 slug + repo URL | 检查逻辑 |

### 3.2 无参调用的调用方

- `health_controller.ex:52` — 健康检查「configured / setup_required」判断
- `orchestrator.ex:2628/2631` — issue 上下文无 workflow 时的回落
- `admin_live/state.ex` 等 UI 层

## 4. 设计方案

### 4.1 `default_project/0` 不再创建 enabled runtime project

```elixir
@spec default_project() :: {:ok, Project.t()} | {:error, :not_found | :repo_unavailable}
def default_project do
  query(:default_project, &default_project!/0)
end

defp default_project! do
  if repo_available?() do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [1_928_374_651])
      create_disabled_default_project_if_empty!()
    end)
  else
    {:error, :repo_unavailable}
  end
end
```

空 projects 表可创建 disabled Default 占位,用于 Settings 引导。它不是 runtime project；
存在任何 project 时不会再创建 Default,缺少 `repository_url` 的历史 Default 占位也会被运行时过滤。

### 4.2 无参 `current_workflow/0` 改为显式解析链

```elixir
def current_workflow do
  query(:current_workflow, fn ->
    case loaded_runtime_workflows() do
      [{%{slug: "default"}, workflow} | _] ->
        workflow

      [{_project, workflow}] ->
        workflow

      [] ->
        nil

      _multiple ->
        {:error, :missing_project_context}
    end
  end)
end
```

解析链:**显式且配置完整的 enabled `slug=default` workflow → 恰好唯一 enabled 且已加载 workflow 的非占位 project → `nil`(setup_required) / `{:error, :missing_project_context}`**。与 `WorkflowStore.default_project_id/2` 的语义对齐,去掉对未配置 Default 占位的 runtime 依赖,并禁止多项目无显式 Default 时按名称或插入顺序猜测项目。

缺少 `repository_url` 的 `slug=default` bootstrap placeholder 是 Settings 引导数据,不是可派发 project。运行时发布快照必须过滤该占位,同时仍保留真实 enabled project 缺少仓库地址时的配置错误。

### 4.3 worker_queue 强制 project_id

`enqueue_task/1` 去掉 `Map.put_new(:project_id, default.id)` 兜底,改为:

```elixir
with {:ok, project_id} <- required_project_id(attrs) do
  # ... attrs 显式带 project_id
end
```

task 必须显式带 `project_id`,不带就返回 `{:error, :project_id_required}`。

### 4.4 first_run 导入目标显式化

`FirstRunDefaults.import_if_needed` 不再硬编码 `default_project()`。交互模式下询问用户选择目标 project(列出 enabled projects),非交互/无 project 时跳过导入并进入 setup_required。

### 4.5 存量数据清理

- `symphony.db` 里 `slug=default` 且未配置仓库地址的 Default 记录删除(或标记 disabled);
- 确认 Koroni、ccrr 两个真实 project 的 workflow 正常加载,无显式 project context 的单项目读取只在恰好一个 enabled loaded workflow 时成功；多项目无配置完整 Default 时返回 `:missing_project_context`;
- 若管理员想要显式 default,可通过新增/修改 project 记录实现(admin UI 或 DB 直改)。

## 5. 兼容性分析

- **健康检查**：无配置完整的 default 且存在多个 enabled loaded workflow 时，`current_workflow()` 返回 `:missing_project_context`，健康检查报告 missing context 而不是 configured。
- **orchestrator 回落**:issue 无显式 workflow 且运行库无法解析唯一 project context 时显式跳过/降级，不按第一个 enabled project 写入持久化记录；需要全部项目时调用 `WorkflowStore.list_enabled()`。
- **admin UI**:selected_project 默认值是 Settings 的界面选择问题,不参与 runtime no-context dispatch 解析。
- **诊断**:setup 检查项不再要求 default project 存在,改为「至少一个 enabled project 配置完整」。
- **破坏性**:删除存量 default 记录后,依赖「default 必存在」的旧逻辑(若有)会暴露;已通过 4.1-4.4 覆盖。

## 6. 影响文件清单

- `lib/symphony_elixir/persistence/workflow_store.ex` — `default_project!/0`、`current_workflow/0`
- `lib/symphony_elixir/workflow_store.ex` — `default_project_id/2`(fallback 不依赖未配置 Default 占位)
- `lib/symphony_elixir/persistence/worker_queue.ex` — `enqueue_task/1`
- `lib/symphony_elixir/first_run_defaults.ex` — `import_if_needed`
- `lib/symphony_elixir_web/controllers/health_controller.ex` — 无参调用确认
- `lib/symphony_elixir/orchestrator.ex` — `current_workflow_record/1` 确认
- `lib/symphony_elixir_web/live/admin_live/state.ex` — `selected_project` 默认值
- `lib/symphony_elixir/linear/diagnostics.ex` — setup 检查项
- `test/` — 相关测试更新

## 7. 验收标准

1. 空库首次启动:`default_project()` 最多创建 disabled Default 占位,不会创建 enabled runtime Default;
2. 有 enabled projects 无配置完整 default：恰好一个 enabled loaded workflow 时 `current_workflow()` 解析到该 workflow；两个或更多 enabled loaded workflows 时返回 `:missing_project_context`；
3. `enqueue_task` 不带 project_id 返回 `{:error, :project_id_required}`;
4. first_run 导入支持选择目标 project;
5. 存量 default 记录清理后,健康检查、orchestrator、admin UI 均正常;
6. `make all` 通过。
