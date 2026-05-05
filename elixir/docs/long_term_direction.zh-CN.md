# Symphony 长期开发方向与技术选型

本文档记录 Symphony Elixir 参考实现的长期开发方向、技术选型和阶段性演进计划。目标是在安全性、性能、开发成本、调试成本之间取得平衡，同时让 Symphony 从当前的实验性编排服务演进为可长期运行、可观测、可配置的 Web 服务。

## 1. 总体方向

Symphony 后续应继续定位为一个长期运行的 Web 服务，而不是一次性 CLI 脚本。核心形态如下：

```text
Elixir / Phoenix Web Service
├── Web UI / Dashboard
├── JSON API
├── SQLite 持久化
├── Workflow / Project 配置管理
├── Orchestrator
├── Agent Run 管理
└── Worker Runtime / Sandbox Runtime
```

短期内继续保留当前 `WORKFLOW.md` 配置模式，逐步引入 SQLite 和 Web UI。长期目标是让 Web UI 成为主要配置入口，同时保留 `WORKFLOW.md` 的导入、导出和版本化能力。

一个关键原则是：`WORKFLOW.md` 的全部内容都应该可配置。这里的“全部”不只包括 Markdown prompt，也包括 YAML front matter 中的 tracker、polling、workspace、hooks、agent、codex、server 等运行配置。Web UI 最终应该能够编辑、校验、版本化和审计整个 workflow contract，而不是只编辑其中一部分。

## 2. 技术选型结论

建议主系统继续使用：

```text
Elixir + OTP + Phoenix LiveView + Ecto + SQLite
```

不建议当前阶段整体重写为 Rust 或纯 Erlang。

Rust 可以作为后续局部组件选项，尤其适合实现高隔离、低权限、可单独分发的 worker runtime 或 sandbox runner。纯 Erlang 可以保留 BEAM/OTP 优势，但对 Web UI、配置表单、数据库开发、模板和日常维护来说，收益不如继续使用 Elixir/Phoenix。

## 3. 为什么继续使用 Elixir/Phoenix

Symphony 的主要工作负载是：

- 轮询 Linear 或其他 tracker。
- 管理 issue/run/workspace 状态。
- 启动和监督 Codex app-server 子进程。
- 维护重试、停止、清理等长期任务生命周期。
- 提供 dashboard、配置 UI 和 JSON API。
- 写入运行事件、日志索引和历史记录。

这些任务主要是 I/O、进程编排和状态管理，不是 CPU 密集型计算。Elixir/OTP 在长期运行、进程监督、失败恢复、消息传递和可观测性方面非常合适。Phoenix LiveView 可以在不引入独立前端项目的情况下构建实时 dashboard 和配置界面。

## 4. 不引入独立 Node 前端项目

长期 Web UI 默认使用 Phoenix LiveView，不引入 React、Vue、Next.js 等独立 Node 前端项目。

推荐 UI 栈：

```text
Phoenix LiveView
HEEx Components
Ecto Forms / Changesets
普通 CSS 或轻量 CSS 架构
少量 LiveView JS Hooks
```

这样可以保持一个 Elixir 应用同时负责：

- 后端编排。
- Web UI。
- 实时状态更新。
- JSON API。
- SQLite 持久化。
- 运维和调试入口。

如果后续需要构建工具，可以使用 Phoenix 自带的轻量 assets 流程，但不要演进成独立前端仓库或复杂 SPA，除非出现明确的产品需求。

## 5. SQLite 持久化方向

当前实现主要依赖内存状态和 `WORKFLOW.md`。长期需要 SQLite 保存运行历史、配置版本和可观测事件。

建议优先引入 Ecto + SQLite，并采用可迁移的数据模型。未来如果需要多用户、多实例或更高并发，可以通过 Ecto 迁移到 Postgres。

初期建议的核心表：

```text
projects
tracker_configs
workflow_versions
issues
runs
agent_turns
workspaces
events
logs
secrets_metadata
```

### 5.1 projects

保存 Symphony 管理的项目。

典型字段：

- `id`
- `name`
- `slug`
- `description`
- `enabled`
- `created_at`
- `updated_at`

### 5.2 tracker_configs

保存 Linear 等 tracker 的连接和筛选配置。

典型字段：

- `id`
- `project_id`
- `kind`
- `project_slug`
- `active_states`
- `terminal_states`
- `api_key_secret_ref`
- `created_at`
- `updated_at`

### 5.3 workflow_versions

保存 workflow 配置和 prompt 的版本。

典型字段：

- `id`
- `project_id`
- `version`
- `yaml_config`
- `prompt_body`
- `raw_workflow_md`
- `source`
- `active`
- `created_at`

每次 agent run 应绑定当时使用的 workflow version，方便后续 debug 和审计。

`raw_workflow_md` 用于保留完整原文，`yaml_config` 和 `prompt_body` 用于结构化读取和 UI 展示。这样可以同时满足机器校验、表单编辑、diff 审计和无损导入/导出。

### 5.4 runs / agent_turns / events

保存执行历史和运行事件。

```text
runs
├── issue_identifier
├── workflow_version_id
├── workspace_path
├── status
├── attempt
├── started_at
├── finished_at
└── failure_reason

agent_turns
├── run_id
├── turn_index
├── status
├── started_at
├── finished_at
└── summary

events
├── project_id
├── run_id
├── issue_identifier
├── event_type
├── payload_json
└── inserted_at
```

## 6. 配置管理演进

配置管理建议分阶段推进，不要一次性删除 `WORKFLOW.md`。

### 阶段 1：保留 WORKFLOW.md，引入运行状态持久化

继续从 `WORKFLOW.md` 读取配置和 prompt，但将以下内容写入 SQLite：

- issue 快照
- run 状态
- agent turn 状态
- workspace 信息
- orchestrator events
- dashboard 所需历史数据

收益：

- dashboard 可以展示历史记录。
- 服务重启后可以恢复更多上下文。
- debug 不再完全依赖日志文件。

### 阶段 2：Web UI 管理配置

将 `WORKFLOW.md` 拆分成可编辑的数据模型。拆分时必须覆盖整个文件，而不是只覆盖 prompt：

- project 配置
- tracker 配置
- polling 配置
- workspace 配置
- hook 配置
- agent 配置
- codex 配置
- server / dashboard 配置
- prompt template

此阶段仍应支持从 `WORKFLOW.md` 导入配置，并支持导出当前配置为 `WORKFLOW.md`。

Web UI 应提供两种编辑模式：

- 表单模式：按 tracker、workspace、hooks、agent、codex、prompt 等区域编辑，并提供字段级校验。
- 原文模式：直接编辑完整 `WORKFLOW.md`，保存时解析、校验并生成新的 workflow version。

两种模式必须写入同一个 workflow version 模型，避免 UI 配置和原始 Markdown 配置分裂。

### 阶段 3：配置版本化

每次配置变更生成新的 `workflow_versions` 记录。每个 run 固定引用一个 workflow version。

这样可以回答：

- 某次 run 当时用了什么 prompt？
- 当时 Codex command 是什么？
- 当时 active states / terminal states 是什么？
- 当时 workspace root、hooks、poll interval、sandbox policy 是什么？
- 某次失败是否由配置变更引起？

### 阶段 4：多项目和多 worker

当单项目模型稳定后，再扩展到：

- 多 project。
- 每个 project 独立 tracker 配置。
- 每个 project 独立 workflow version。
- 多 worker runtime。
- 不同 worker 的资源限制和安全策略。

## 7. Web UI 方向

Web UI 应优先服务运维、配置和调试，不做营销型页面。

Dashboard 的长期视觉语言应使用语义化配色，而不是临时页面级颜色。推荐采用 [Dashboard 配色系统设计](dashboard_color_system_design.zh-CN.md)：以杰尼龟蓝、小火龙橙、妙蛙种子绿和皮卡丘黄作为灵感来源，落地为 primary、warning、success、accent 等低饱和 CSS token。UI 不使用角色图片、商标素材或游戏化大面积装饰。

建议页面：

```text
/
├── Dashboard
├── Projects
│   ├── Project Detail
│   ├── Tracker Settings
│   ├── Workflow Settings
│   └── Worker Settings
├── Issues
│   └── Issue Detail
├── Runs
│   └── Run Detail
├── Workspaces
├── Events
├── Logs
└── Settings
```

核心能力：

- 查看当前 orchestrator 状态。
- 查看 active runs、queued issues、backoff queue。
- 查看每个 issue 的 workspace、attempt、agent turn、最近事件。
- 查看 run 历史。
- 查看 workflow version 和配置 diff。
- 暂停/恢复 project。
- 手动 refresh tracker。
- 停止、重试、清理 run。
- 配置 Linear project slug、active states、terminal states。
- 配置 workspace root、hooks、Codex command。
- 编辑完整 `WORKFLOW.md`，包括 YAML front matter 和 Markdown prompt。
- 预览 workflow diff，并在保存前运行 schema 校验。
- 查看每个 run 绑定的 workflow version 和原始 workflow 内容。

## 8. 安全方向

安全性不应主要依赖语言选择，而应依赖明确的执行边界。

长期应加强：

- Dashboard/API 鉴权。
- CSRF 和安全 header。
- secrets 不明文回显。
- Codex command 不默认继承全部环境变量。
- workspace root 路径严格校验。
- workspace 删除操作必须受路径约束。
- hooks 提供 UI 风险提示和审计记录。
- agent run 使用最小权限环境变量。
- 每个 run 记录审计事件。
- 支持本地 worker、Docker worker、SSH worker 等隔离等级。

建议安全模型：

```text
Phoenix Web / Orchestrator
└── Worker Runtime
    ├── Local Worker: 开发和可信环境
    ├── Docker Worker: 中等隔离
    ├── SSH Worker: 远程隔离
    └── Future Rust Sandbox Runner: 更强边界
```

Rust 的优先使用位置不是主 Web 服务，而是未来的 sandbox runner 或 worker launcher。

## 9. 性能方向

当前系统的性能瓶颈更可能来自：

- Linear API。
- Git 操作。
- Codex app-server 子进程。
- workspace 文件系统 I/O。
- 测试命令执行时间。

BEAM 本身不是主要瓶颈。短中期性能优化重点应放在：

- 控制并发。
- tracker polling 节流。
- 对外部 API 做 retry/backoff。
- 减少重复 workspace 初始化。
- 将大日志流写入文件或事件表，而不是全部放内存。
- dashboard 查询做分页。
- run/event 表加索引。
- 长任务与 Web 请求解耦。

## 10. Debug 和可观测性方向

长期应将 debug 从“看终端输出”升级为“看结构化运行历史”。

建议统一事件模型：

```text
event_type:
  workflow.loaded
  tracker.polled
  issue.discovered
  run.started
  workspace.created
  hook.started
  hook.finished
  codex.started
  codex.turn.started
  codex.turn.finished
  run.retry_scheduled
  run.failed
  run.completed
  workspace.cleaned
```

每条事件应包含：

- `project_id`
- `issue_identifier`
- `run_id`
- `attempt`
- `event_type`
- `payload_json`
- `inserted_at`

Dashboard 和 JSON API 都应基于同一套状态/事件数据，而不是各自拼装。

## 11. 模块边界建议

长期代码边界建议保持如下分层：

```text
lib/symphony_elixir/
├── orchestration/     # 调度、状态机、重试、run lifecycle
├── workflows/         # workflow config、version、prompt template
├── trackers/          # Linear 等外部 tracker adapter
├── workers/           # local/docker/ssh worker runtime
├── codex/             # codex app-server client 和 dynamic tools
├── persistence/       # Ecto schemas、repo、queries
├── observability/     # events、logs、telemetry
└── security/          # secrets、auth、policy、path safety

lib/symphony_elixir_web/
├── live/
├── controllers/
├── components/
└── presenters/
```

当前代码不需要一次性重构到这个结构，但新增 SQLite 和 Web UI 时应向这个方向靠拢。

## 12. 推荐路线图

### Milestone 1：持久化运行状态

- 引入 `ecto_sqlite3`。
- 新增 Repo 和 migration。
- 保存 runs、agent_turns、events。
- Dashboard 从 DB 查询历史数据。
- 保留现有 `WORKFLOW.md` 配置来源。

### Milestone 2：Dashboard 升级

- 增加 run detail 页面。
- 增加 issue detail 页面。
- 增加 events/logs 页面。
- 支持分页、筛选和刷新。
- 支持手动 retry / stop / refresh。

### Milestone 3：配置 UI

- 新增 projects。
- 新增 tracker config UI。
- 新增 workflow config UI。
- 支持导入/导出 `WORKFLOW.md`。
- 支持完整编辑 `WORKFLOW.md` 的 YAML front matter 和 Markdown prompt。
- 支持表单模式和原文模式之间互相同步。
- 保存前执行 schema 校验和 prompt 模板校验。
- 每次保存生成 workflow version。

### Milestone 4：安全和权限

- Dashboard/API 加认证。
- secrets metadata 入库。
- secrets 明文只通过受控注入路径使用。
- 增加 hook 审计事件。
- 收紧 Codex environment inheritance。

### Milestone 5：Worker Runtime 分层

- 将 local run 逻辑抽象为 worker behavior。
- 支持 Panel / Worker 解耦：Panel 负责调度、配置、持久化和 UI，Worker 主动连接 Panel、握手、心跳、领取任务并回传结果。
- 当前 Elixir 仓库优先实现 Panel / 服务端能力；生产 worker 按前序技术选型方向使用 Rust 实现，并通过稳定 JSON/HTTP 协议接入 Panel。
- 详细设计见 [Panel / Worker 解耦设计](worker_panel_decoupling_design.zh-CN.md)。
- 增加 worker identity、worker session、task queue、task lease、heartbeat 和 capability matching。
- 设计 worker API 协议版本、预共享注册 token、租约续期、任务取消、late completion 处理和 dashboard 可观测事件。
- 保留 local worker。
- 稳定 SSH worker。
- 增加 Docker worker。
- 评估是否需要 Rust sandbox runner。

## 13. 明确不做或暂缓

短期不建议：

- 整体重写为 Rust。
- 整体重写为纯 Erlang。
- 引入独立 Node 前端项目。
- 将 Dashboard 做成复杂 SPA。
- 过早支持多租户。
- 过早设计分布式数据库或多实例调度。

这些方向不是永远不能做，而是当前收益不足以抵消复杂度。

## 14. 总结

Symphony 的长期主线应是：

```text
保留 Elixir/Phoenix 主系统
引入 Ecto + SQLite 持久化
用 LiveView 构建 Dashboard 和配置 UI
逐步从 WORKFLOW.md 迁移到完整可配置、可版本化的 workflow contract
把安全隔离下沉到 worker runtime
必要时用 Rust 实现局部 sandbox/worker 组件
```

这条路线能最大化复用当前实现，同时兼顾安全性、性能、开发效率和调试成本。
