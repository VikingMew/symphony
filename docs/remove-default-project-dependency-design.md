---
title: 去除 Default Project 强制依赖设计(Multi-Project First)
genre: design
domain: [workflow, projects, persistence]
status: current
language: zh-CN
updated: 2026-08-09
design_status: proposed
---

# 去除 Default Project 强制依赖设计

## 1. 背景

Symphony 当前架构里存在一个「default project」的隐式强制依赖:只要数据库里没有 `slug="default"` 的 Project 记录,任何调用 `default_project()` 的地方都会**自动创建**一个 `{name: "Default", slug: "default", default_branch: "main", enabled: true}` 记录。当前运行库(`symphony.db`)里那个 `slug=default` 的 Default 记录就是这么来的。

这带来三个问题:

1. **设计不需要它**:Symphony 的设计是多 project 并行(Koroni、ccrr 等真实 project 各自有自己的 workflow),不存在「默认 project」的概念,却被迫存在一个自动创建的魔法记录。
2. **隐式行为掩盖配置错误**:自动创建导致「未配置任何 project」和「已配置但缺 default」无法区分——系统永远看起来有 default,真实配置状态被掩盖。
3. **单 project 时代的遗留**:无参 `active_workflow_version()`、`current()` 的默认解析、worker_queue 的 project 兜底、first_run 导入目标,全部硬编码依赖 default project,与多 project 设计冲突。

## 2. 目标

把「隐式自动创建的 default project」改为「显式 project 上下文」:

- `default_project()` 不再自动创建记录,不存在就返回 `{:error, :not_found}`,由上层显式处理;
- 无参 `active_workflow_version()` 按「显式配置的 default slug → 第一个 enabled project → `:no_active_workflow`」解析,不依赖自动创建的记录;
- worker_queue 的 task 必须显式带 project_id,不带就报错;
- first_run 导入目标显式化,不再硬编码 default;
- 存量 `slug=default` 记录清理,真实 project(Koroni、ccrr)成为唯一事实来源。

## 3. 现状分析

### 3.1 强制依赖点

| 位置 | 行为 | 依赖 |
| --- | --- | --- |
| `Persistence.WorkflowStore.default_project!/0` (persistence/workflow_store.ex:20-34) | 查 `slug="default"`,没有就 insert | **自动创建(根因)** |
| `Persistence.WorkflowStore.active_workflow_version/0` (persistence/workflow_store.ex:79-87) | 无参版先 `default_project()` 再查 | 无参调用需要 default |
| `WorkflowStore.load_database_workflows` (workflow_store.ex:221-230) | 加载全部 enabled projects 的 workflow,`default_project_id` 优先 default 再 fallback 第一个 | default 优先解析 |
| `WorkflowStore.default_project_id/2` (workflow_store.ex:272-277) | default 在 workflows 里就用它的 id,否则取第一个 | default 优先 |
| `Persistence.WorkerQueue.enqueue_task/1` (worker_queue.ex:79) | task 不带 project 就 `Map.put_new(:project_id, default.id)` | **静默兜底** |
| `FirstRunDefaults.import_if_needed` (first_run_defaults.ex:82) | 导入默认 workflow 必须 `default_project()` | 导入目标硬编码 |
| `HealthController.workflow_state/1` (health_controller.ex:52) | `active_workflow_version()` 无参判断 setup 状态 | 无参调用 |
| `Orchestrator.context_workflow_version/1` (orchestrator.ex:2628/2631) | issue 无显式 workflow_version_id 时回落 `active_workflow_version()` | 无参调用 |
| `AdminLive.State` / `WorkflowState` | admin 界面 selected_project 默认 default | UI 默认值 |
| `Linear.Diagnostics` | setup 检查项要求 default project 有 slug + repo URL | 检查逻辑 |

### 3.2 无参调用的调用方

- `health_controller.ex:52` — 健康检查「configured / setup_required」判断
- `orchestrator.ex:2628/2631` — issue 上下文无 workflow 时的回落
- `admin_live/state.ex` 等 UI 层

## 4. 设计方案

### 4.1 `default_project/0` 改为纯查询

```elixir
@spec default_project() :: {:ok, Project.t()} | {:error, :not_found | :repo_unavailable}
def default_project do
  query(:default_project, &default_project!/0)
end

defp default_project! do
  if repo_available?() do
    case Repo.get_by(Project, slug: @default_project_slug) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  else
    {:error, :repo_unavailable}
  end
end
```

不再自动 insert。语义:default project 是**可选配置**,不是必然存在。

### 4.2 无参 `active_workflow_version/0` 改为显式解析链

```elixir
def active_workflow_version do
  query(:active_workflow_version, fn ->
    case default_project() do
      {:ok, project} -> active_workflow_version(project)
      {:error, :not_found} ->
        # 没有显式 default 时,取第一个 enabled project(与 WorkflowStore 的
        # default_project_id fallback 一致)
        case first_enabled_project() do
          {:ok, project} -> active_workflow_version(project)
          :none -> nil
        end
      {:error, :repo_unavailable} -> nil
    end
  end)
end
```

解析链:**显式 default slug(DB 记录)→ 第一个 enabled project → `nil`(setup_required)**。与 `WorkflowStore.default_project_id/2` 的 fallback 语义对齐,去掉对自动创建记录的依赖。

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

- `symphony.db` 里 `slug=default` 的 Default 记录删除(或标记 disabled);
- 确认 Koroni、ccrr 两个真实 project 的 workflow 正常加载,`current()` 解析到第一个 enabled project 的 workflow;
- 若管理员想要显式 default,可通过新增/修改 project 记录实现(admin UI 或 DB 直改)。

## 5. 兼容性分析

- **健康检查**:无 default 但有 enabled project 时,`active_workflow_version()` 解析到第一个 enabled project 的 workflow,健康检查仍报 configured,行为不变。
- **orchestrator 回落**:issue 无显式 workflow 时回落第一个 enabled project 的 workflow,与当前 `default_project_id` 的 fallback 行为一致。
- **admin UI**:selected_project 默认值从 default 改为第一个 enabled project。
- **诊断**:setup 检查项不再要求 default project 存在,改为「至少一个 enabled project 配置完整」。
- **破坏性**:删除存量 default 记录后,依赖「default 必存在」的旧逻辑(若有)会暴露;已通过 4.1-4.4 覆盖。

## 6. 影响文件清单

- `lib/symphony_elixir/persistence/workflow_store.ex` — `default_project!/0`、`active_workflow_version/0`
- `lib/symphony_elixir/workflow_store.ex` — `default_project_id/2`(语义保持,确认 fallback 不依赖自动创建)
- `lib/symphony_elixir/persistence/worker_queue.ex` — `enqueue_task/1`
- `lib/symphony_elixir/first_run_defaults.ex` — `import_if_needed`
- `lib/symphony_elixir_web/controllers/health_controller.ex` — 无参调用确认
- `lib/symphony_elixir/orchestrator.ex` — `context_workflow_version/1` 确认
- `lib/symphony_elixir_web/live/admin_live/state.ex` — `selected_project` 默认值
- `lib/symphony_elixir/linear/diagnostics.ex` — setup 检查项
- `test/` — 相关测试更新

## 7. 验收标准

1. 空库首次启动:`default_project()` 返回 `{:error, :not_found}`,不再自动创建 Default 记录;
2. 有 enabled projects 无 default:`active_workflow_version()` 解析到第一个 enabled project 的 workflow;
3. `enqueue_task` 不带 project_id 返回 `{:error, :project_id_required}`;
4. first_run 导入支持选择目标 project;
5. 存量 default 记录清理后,健康检查、orchestrator、admin UI 均正常;
6. `make all` 通过。
