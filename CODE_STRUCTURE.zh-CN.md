# Symphony 代码结构说明

这份文档面向“读代码”和“改代码”的场景，说明仓库目录如何组织、核心模块分别负责什么，以及常见需求应该从哪些文件开始看。

## 1. 仓库整体结构

```text
.
├── README.md
├── SPEC.md
├── ARCHITECTURE.md
├── CODE_STRUCTURE.md
├── CODE_STRUCTURE.zh-CN.md
├── LICENSE
├── NOTICE
├── .codex/
│   ├── skills/
│   └── worktree_init.sh
└── elixir/
    ├── README.md
    ├── WORKFLOW.md
    ├── AGENTS.md
    ├── Makefile
    ├── mise.toml
    ├── mix.exs
    ├── mix.lock
    ├── config/
    ├── docs/
    ├── lib/
    ├── priv/
    └── test/
```

根目录主要放产品说明、协议规范和项目级文档。真正可运行的参考实现位于 `elixir/`。

## 2. 根目录文件

| 路径 | 作用 |
| --- | --- |
| `README.md` | 项目概览，并指向 Elixir 参考实现。 |
| `SPEC.md` | 与语言无关的 Symphony 服务规范。 |
| `ARCHITECTURE.md` | 整体架构和运行时设计。 |
| `CODE_STRUCTURE.md` | 英文代码结构说明。 |
| `CODE_STRUCTURE.zh-CN.md` | 中文代码结构说明。 |
| `.codex/skills/*` | 仓库内置 Codex skills，供 workflow prompt 调用。 |
| `.codex/worktree_init.sh` | Codex worktree 初始化辅助脚本。 |

## 3. Elixir 项目根目录

```text
elixir/
├── README.md
├── WORKFLOW.md
├── AGENTS.md
├── Makefile
├── mise.toml
├── mix.exs
├── mix.lock
├── config/config.exs
├── lib/
└── test/
```

| 路径 | 作用 |
| --- | --- |
| `elixir/README.md` | Elixir 实现的安装、运行、配置、测试和 FAQ。 |
| `elixir/WORKFLOW.md` | 默认工作流文件，包含 YAML 运行配置和发给 Codex 的 Markdown prompt。 |
| `elixir/AGENTS.md` | 给 agent 阅读的仓库级工作指引。 |
| `elixir/Makefile` | 常用开发命令，如 `test`、`lint`、`coverage`、`ci`、`e2e`。 |
| `elixir/mise.toml` | 运行时工具版本：Erlang 28、Elixir 1.19.5 OTP 28。 |
| `elixir/mix.exs` | Mix 项目定义，包含依赖、alias、escript 构建配置。 |
| `elixir/config/config.exs` | Phoenix/Bandit endpoint 和 JSON 配置。 |
| `elixir/priv/repo/migrations` | SQLite/Ecto migration。 |
| `elixir/docs` | 用户指南、设计、日志、token 统计和已完成计划文档。 |

## 4. 应用启动入口

核心文件：

- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/cli.ex`

`SymphonyElixir.CLI` 是命令行入口，会被编译成 `elixir/bin/symphony`。它负责解析 CLI 参数、校验 workflow 文件路径、设置运行时覆盖项，然后启动 OTP 应用。

`SymphonyElixir.Application` 定义在 `elixir/lib/symphony_elixir.ex` 中，是 OTP 应用入口。它启动的监督树如下：

```text
SymphonyElixir.Supervisor
├── SymphonyElixir.Repo（MIX_ENV=test 时跳过）
├── Phoenix.PubSub
├── Task.Supervisor
├── SymphonyElixir.WorkflowStore
├── SymphonyElixir.Orchestrator
├── SymphonyElixir.HttpServer
└── SymphonyElixir.StatusDashboard
```

`SymphonyElixir` 模块本身很薄，只是对 `SymphonyElixir.Orchestrator.start_link/1` 做了一层封装。

## 5. 核心运行时代码

```text
elixir/lib/symphony_elixir/
├── agent_runner.ex
├── cli.ex
├── config.ex
├── config/schema.ex
├── http_server.ex
├── log_file.ex
├── orchestrator.ex
├── path_safety.ex
├── persistence.ex
├── persistence/
├── persistence_provider.ex
├── prompt_builder.ex
├── repo.ex
├── specs_check.ex
├── ssh.ex
├── status_dashboard.ex
├── tracker.ex
├── workflow.ex
├── workflow_store.ex
└── workspace.ex
```

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `SymphonyElixir.Application` | `symphony_elixir.ex` | OTP 应用入口和监督树定义。 |
| `SymphonyElixir.CLI` | `cli.ex` | CLI 参数解析、guardrail 确认、workflow 路径设置、应用启动。 |
| `SymphonyElixir.Workflow` | `workflow.ex` | workflow 文件路径管理和解析入口。 |
| `SymphonyElixir.WorkflowStore` | `workflow_store.ex` | 保存当前 workflow 状态，以及最后一次可用的正确配置。 |
| `SymphonyElixir.Config` | `config.ex` | 为 workflow 配置提供带默认值的类型化读取接口。 |
| `SymphonyElixir.Config.Schema` | `config/schema.ex` | 配置 schema 和校验规则。 |
| `SymphonyElixir.Orchestrator` | `orchestrator.ex` | 轮询、派发、并发控制、active run 跟踪、重试、清理、状态生成。 |
| `SymphonyElixir.Tracker` | `tracker.ex` | issue tracker 抽象接口，供 orchestrator 使用。 |
| `SymphonyElixir.Workspace` | `workspace.ex` | workspace 路径解析、创建、生命周期 hook、清理。 |
| `SymphonyElixir.PathSafety` | `path_safety.ex` | workspace 路径安全校验辅助逻辑。 |
| `SymphonyElixir.AgentRunner` | `agent_runner.ex` | 为 issue 创建 prompt，并运行 Codex App Server session。 |
| `SymphonyElixir.PromptBuilder` | `prompt_builder.ex` | 将 issue 数据渲染进 workflow prompt 模板。 |
| `SymphonyElixir.HttpServer` | `http_server.ex` | 启动可选 Phoenix/Bandit 观测 HTTP 服务。 |
| `SymphonyElixir.StatusDashboard` | `status_dashboard.ex` | 终端/operator 状态展示。 |
| `SymphonyElixir.LogFile` | `log_file.ex` | 运行日志文件配置和写入。 |
| `SymphonyElixir.Persistence` | `persistence.ex` | SQLite-backed projects、workflow、runs、tasks、workers、leases 和 events。 |
| `SymphonyElixir.PersistenceProvider` | `persistence_provider.ex` | 测试中替换 persistence fake 的运行时边界。 |
| `SymphonyElixir.Repo` | `repo.ex` | Ecto repository。 |
| `SymphonyElixir.SSH` | `ssh.ex` | SSH worker 支持。 |
| `SymphonyElixir.SpecsCheck` | `specs_check.ex` | 内部规范一致性检查。 |

## 6. Tracker 和 Linear 集成

```text
elixir/lib/symphony_elixir/linear/
├── adapter.ex
├── client.ex
└── issue.ex

elixir/lib/symphony_elixir/tracker/
└── memory.ex
```

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `SymphonyElixir.Linear.Adapter` | `linear/adapter.ex` | Linear 版本的 tracker adapter。 |
| `SymphonyElixir.Linear.Client` | `linear/client.ex` | 底层 Linear API 请求。 |
| `SymphonyElixir.Linear.Issue` | `linear/issue.ex` | 标准化后的 issue 结构。 |
| `SymphonyElixir.Tracker.Memory` | `tracker/memory.ex` | 内存版 tracker，主要用于测试和本地模拟。 |

`Orchestrator` 依赖的是 `Tracker` 抽象，而不是直接依赖 Linear。这样调度逻辑和外部 API 细节可以分开。

## 7. Codex 集成

```text
elixir/lib/symphony_elixir/codex/
├── app_server.ex
└── dynamic_tool.ex
```

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `SymphonyElixir.Codex.AppServer` | `codex/app_server.ex` | 启动并通信 `codex app-server`。 |
| `SymphonyElixir.Codex.DynamicTool` | `codex/dynamic_tool.ex` | 定义暴露给 Codex session 的客户端 dynamic tools。 |

其中最重要的 dynamic tool 是 `linear_graphql`，它允许仓库 skills 在 agent session 中直接执行 Linear GraphQL 操作。

## 8. Web 观测模块

```text
elixir/lib/symphony_elixir_web/
├── auth_plug.ex
├── components/layouts.ex
├── controllers/
│   ├── observability_api_controller.ex
│   ├── session_controller.ex
│   ├── static_asset_controller.ex
│   └── worker_api_controller.ex
├── endpoint.ex
├── error_html.ex
├── error_json.ex
├── live/admin_live.ex
├── live/dashboard_live.ex
├── live/linear_diagnostics_live.ex
├── observability_pubsub.ex
├── presenter.ex
├── router.ex
└── static_assets.ex
```

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `SymphonyElixirWeb.Endpoint` | `endpoint.ex` | Phoenix endpoint。 |
| `SymphonyElixirWeb.Router` | `router.ex` | dashboard、静态资源和 JSON API 的路由。 |
| `SymphonyElixirWeb.AuthPlug` | `auth_plug.ex` | 可选 browser/API 登录认证入口。 |
| `SymphonyElixirWeb.SessionController` | `controllers/session_controller.ex` | 登录/登出 controller。 |
| `SymphonyElixirWeb.DashboardLive` | `live/dashboard_live.ex` | LiveView dashboard 页面。 |
| `SymphonyElixirWeb.AdminLive` | `live/admin_live.ex` | projects、runs、workers、workflows、settings 管理页面。 |
| `SymphonyElixirWeb.LinearDiagnosticsLive` | `live/linear_diagnostics_live.ex` | Linear 诊断页面。 |
| `SymphonyElixirWeb.ObservabilityApiController` | `controllers/observability_api_controller.ex` | 运行状态 JSON API 和刷新接口。 |
| `SymphonyElixirWeb.WorkerApiController` | `controllers/worker_api_controller.ex` | 外部 worker 注册、领取任务、心跳和事件 API。 |
| `SymphonyElixirWeb.StaticAssetController` | `controllers/static_asset_controller.ex` | 提供内置静态资源。 |
| `SymphonyElixirWeb.Presenter` | `presenter.ex` | 将 runtime state 转换成 UI/API 展示数据。 |
| `SymphonyElixirWeb.ObservabilityPubSub` | `observability_pubsub.ex` | dashboard 状态更新的 PubSub 辅助模块。 |
| `SymphonyElixirWeb.StaticAssets` | `static_assets.ex` | 静态资源查找。 |
| `SymphonyElixirWeb.ErrorHTML` | `error_html.ex` | HTML 错误响应。 |
| `SymphonyElixirWeb.ErrorJSON` | `error_json.ex` | JSON 错误响应。 |

主要路由：

```text
GET  /                         LiveView dashboard
GET  /login                    登录页面（启用认证时使用）
GET  /projects                 项目管理
GET  /runs                     run 历史
GET  /workers                  worker、task 和 lease 状态
GET  /workflows                workflow 原文编辑和版本历史
GET  /settings                 运行配置摘要
GET  /diagnostics/linear       Linear 诊断
GET  /dashboard.css             Dashboard 样式
GET  /api/v1/state              完整运行状态 JSON
POST /api/v1/refresh            触发刷新
GET  /api/v1/:issue_identifier  单个 issue 的状态 JSON
POST /api/worker/v1/register    worker 注册
POST /api/worker/v1/tasks/claim worker 领取任务
POST /api/worker/v1/heartbeat   worker 心跳和 lease 续期
POST /api/worker/v1/tasks/:id/events worker task 事件上报
```

## 9. Mix Tasks

```text
elixir/lib/mix/tasks/
├── pr_body.check.ex
├── specs.check.ex
├── symphony.build.ex
└── workspace.before_remove.ex
```

| Task | 作用 |
| --- | --- |
| `mix pr_body.check` | 检查 PR body 是否符合预期。 |
| `mix specs.check` | 检查实现和规范的一致性。 |
| `mix symphony.build` | 构建 `mix build` 使用的 escript 可执行文件。 |
| `mix workspace.before_remove` | workspace 删除前使用的 hook task。 |

## 10. 测试结构

```text
elixir/test/
├── mix/tasks/
├── support/
└── symphony_elixir/
```

| 路径 | 作用 |
| --- | --- |
| `test/symphony_elixir/core_test.exs` | 核心编排行为测试。 |
| `test/symphony_elixir/workspace_and_config_test.exs` | workspace 和配置行为测试。 |
| `test/symphony_elixir/app_server_test.exs` | Codex App Server 集成行为测试。 |
| `test/symphony_elixir/dynamic_tool_test.exs` | dynamic tool 行为测试。 |
| `test/symphony_elixir/cli_test.exs` | CLI 参数和启动行为测试。 |
| `test/symphony_elixir/orchestrator_status_test.exs` | Orchestrator 状态输出测试。 |
| `test/symphony_elixir/status_dashboard_log_test.exs` | 状态 dashboard 日志渲染和旧格式回归测试。 |
| `test/symphony_elixir/auth_persistence_web_test.exs` | 认证和 persistence-backed Web UI 行为测试。 |
| `test/symphony_elixir/observability_pubsub_test.exs` | 观测 PubSub 行为测试。 |
| `test/symphony_elixir/log_file_test.exs` | 日志文件行为测试。 |
| `test/symphony_elixir/persistence_provider_test.exs` | persistence provider 边界行为测试。 |
| `test/symphony_elixir/web_fake_persistence_test.exs` | Web 和 worker API 的 fake persistence 行为测试。 |
| `test/symphony_elixir/linear_diagnostics_test.exs` | Linear 诊断行为和路由保护测试。 |
| `test/symphony_elixir/ssh_test.exs` | SSH worker 行为测试。 |
| `test/symphony_elixir/live_e2e_test.exs` | 真实外部端到端测试，会使用 Linear 和 Codex。 |
| `test/mix/tasks/*_test.exs` | 自定义 Mix tasks 测试。 |
| `test/support/*` | 测试辅助模块。 |

## 11. 主调用链

启动链路：

```text
bin/symphony
└── SymphonyElixir.CLI.main/1
    └── SymphonyElixir.CLI.evaluate/2
        └── Application.ensure_all_started(:symphony_elixir)
            └── SymphonyElixir.Application.start/2
                ├── SymphonyElixir.Repo
                ├── SymphonyElixir.WorkflowStore
                ├── SymphonyElixir.Orchestrator
                ├── SymphonyElixir.HttpServer
                └── SymphonyElixir.StatusDashboard
```

issue 执行链路：

```text
SymphonyElixir.Orchestrator
├── 从 WorkflowStore / Config 读取配置
├── 通过 Tracker / Linear.Adapter 拉取 issues
├── centralized 模式：通过 Workspace 准备 issue workspace
├── centralized 模式：通过 PromptBuilder 渲染 prompt
├── centralized 模式：通过 AgentRunner 启动 agent run
├── centralized 模式：通过 Codex.AppServer 与 Codex app-server 通信
└── worker 模式：持久化 run/task，等待 WorkerApiController 被外部 worker claim
```

## 12. 常见修改入口

| 需求 | 优先查看文件 |
| --- | --- |
| 修改 CLI 参数或启动行为 | `elixir/lib/symphony_elixir/cli.ex` |
| 修改 workflow 解析或 reload 行为 | `workflow.ex`, `workflow_store.ex` |
| 新增配置字段或默认值 | `config.ex`, `config/schema.ex` |
| 修改轮询、派发、重试、清理逻辑 | `orchestrator.ex` |
| 修改 workspace 路径或 hook 行为 | `workspace.ex`, `path_safety.ex` |
| 修改 prompt 渲染逻辑 | `prompt_builder.ex` |
| 修改 Linear API 行为 | `linear/adapter.ex`, `linear/client.ex`, `linear/issue.ex` |
| 新增另一个 tracker | `tracker.ex`，然后实现新的 adapter 模块 |
| 修改 Codex app-server 协议处理 | `codex/app_server.ex` |
| 修改暴露给 Codex 的 dynamic tools | `codex/dynamic_tool.ex` |
| 修改 dashboard UI | `symphony_elixir_web/live/dashboard_live.ex`, `symphony_elixir_web/live/admin_live.ex`, `presenter.ex` |
| 修改 JSON 观测 API | `symphony_elixir_web/controllers/observability_api_controller.ex` |
| 修改 worker API 行为 | `symphony_elixir_web/controllers/worker_api_controller.ex`, `persistence.ex` |
| 修改 persistence schema | `persistence/*.ex`, `priv/repo/migrations/*` |
| 修改认证行为 | `symphony_elixir_web/auth_plug.ex`, `controllers/session_controller.ex` |
| 修改终端状态展示 | `status_dashboard.ex` |
| 修改核心编排测试 | `test/symphony_elixir/core_test.exs` |

## 13. 开发命令

在 `elixir/` 目录下运行：

```bash
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix test
mise exec -- make all
```

真实外部端到端测试：

```bash
export LINEAR_API_KEY=...
mise exec -- make e2e
```
