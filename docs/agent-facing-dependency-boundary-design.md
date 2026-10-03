---
title: 面向 Agent 的依赖与边界设计
genre: design
domain: [agents, dependencies, boundaries, testing]
status: current
language: zh-CN
updated: 2026-09-24
design_status: landed
---

# 面向 Agent 的依赖与边界设计

本文是 Symphony 仓库 P-01 至 P-06 的唯一 L3 owner。它拥有直接依赖分类、核心/边界划分、
审计结论和常驻检查合同；其他文档只链接本文，不重复维护另一份 P 组合同。

## 依赖和模块边界

`mix.exs` 的每个直接依赖恰好属于下表一个角色。框架、数据格式和测试/质量工具可以在其职责内
直接使用；外部 transport 只能由边界模块引用。这个划分要求真实的远程或存储 I/O 留在边界，
不要求为纯数据转换或框架回调增加无消费者的包装层。

| 角色 | 直接依赖 | 使用合同 |
| --- | --- | --- |
| runtime framework | `bandit`, `ecto`, `ecto_sql`, `phoenix`, `phoenix_html`, `phoenix_live_view` | Web、schema/query 和 OTP 集成可直接使用。 |
| data format | `jason`, `solid`, `yaml_elixir` | 纯编码、模板和配置解析可直接使用。 |
| boundary transport | `castore`, `postgrex`, `req` | 只允许在下列远程、存储或命令边界内出现。 |
| test only | `floki`, `lazy_html` | 只参与测试编译。 |
| quality tool | `credo`, `dialyxir` | 只参与开发质量检查。 |

核心是 `lib/` 中除以下边界外的生产模块。边界模块按当前消费者声明为：

- 远程服务：`SymphonyElixir.Linear.*`、`SymphonyElixir.GitHub.*`、
  `SymphonyElixir.Worker.Client` 和执行文档漂移远程读取的 `Mix.Tasks.Docs.Drift`。
- 存储：`SymphonyElixir.Repo`、`SymphonyElixir.Persistence` 及其子模块、
  `SymphonyElixir.PRReview.Store`、数据库启动/迁移/release/import 模块。
- 启动与共享状态：`SymphonyElixir.CLI`、`SymphonyElixir.HttpServer`、
  `SymphonyElixir.Workflow` 和 `SymphonyElixir.WorkflowStore`。

`test/symphony_elixir/dependency_boundary_governance_test.exs` 从 Mix project 读取直接依赖，保证分类
无遗漏且不重复；它再解析所有 `lib/**/*.ex` 的 Elixir AST，禁止核心引用 `CAStore`、`Postgrex`
或 `Req`。错误包含具体文件、模块、行号和依赖名。

## 对外接口审计

下表审计仓库自己控制的集成边界。必填项都通过函数参数或结构体显式提供，默认值只用于可选
执行策略；本次没有发现需要改造的宽接口。

| 接口 | 参数 | 必填项 | 默认值 | 人工结论 |
| --- | --- | --- | --- | --- |
| `SymphonyElixir.Tracker.fetch_candidate_issues/0` | 无 | 无 | 无 | 窄入口，adapter 从当前配置注入。 |
| `Tracker.fetch_issues_by_states/1`, `fetch_issue_states_by_ids/1` | state/id 列表 | 列表 | 无 | 查询范围显式。 |
| `Tracker.fetch_review_context/1`, `create_comment/2`, `update_issue_state/2` | issue id，加 body/state | 全部 | 无 | 写入目标和内容显式。 |
| `SymphonyElixir.GitHub.PullRequest.mergeability/3` | issue、project、opts | issue、project | `opts: []` | opts 只承载可注入 transport/command runner。 |
| `GitHub.PullRequest.ensure_open/4` | issue、project、rendered、opts | 前三项 | `opts: []` | repository/base/head 和正文必须显式。 |
| `GitHub.PullRequest.review_context/2` | job、opts | job | `opts: []` | job 固定 PR 身份，opts 只用于边界注入。 |
| `SymphonyElixir.Worker.Client.register/1`, `claim/2`, `heartbeat/3`, `event/5` | worker config 与协议 payload | 全部 | 无 | 身份、lease/task 和 payload 均显式。 |
| `SymphonyElixir.PersistenceProvider.read/1`, `publish_runtime_mutation/1` | 函数或 persistence result | 全部 | 无 | 核心只依赖 provider contract。 |

## 离线核心测试

依赖准备完成后，`HEX_OFFLINE=1 scripts/core_test.sh` 运行纯核心与治理测试。入口不执行
`mix deps.get`，测试环境由 `test/symphony_elixir/default_test_boundary_test.exs` 断言不启动 Repo 或
HTTP server；所选测试不调用 live Linear、GitHub 或 PostgreSQL。`scripts/unit.sh` 先准备依赖，再以
`HEX_OFFLINE=1` 调用该入口，最后运行完整默认测试和覆盖率。

## 跨调用状态审计

AST 检查禁止未声明模块调用 `Application.put_env/delete_env`、`:persistent_term.put/erase` 或
`Process.register`。当前允许的写入都有一个明确 owner：

| Owner | 状态 | 理由 |
| --- | --- | --- |
| `SymphonyElixir.CLI` | CLI 解析后的日志路径、端口和启动选项 | 应用启动边界把一次性参数交给 supervision tree。 |
| `SymphonyElixir.HttpServer` | Endpoint 启动配置 | 启动 Phoenix endpoint 前必须发布最终监听配置。 |
| `SymphonyElixir.Workflow` | example/import 文件路径 | 测试与一次性 package import 边界需要切换输入并触发 reload。 |
| `SymphonyElixir.WorkflowStore` | 原子 workflow snapshot | 命名 GenServer 是唯一 writer，`:persistent_term` 为并发 reader 发布一份快照。 |
| `SymphonyElixir.Orchestrator` | listening、active run、retry 和调度状态 | 单一 mailbox 串行化 orchestration state machine。 |
| `SymphonyElixir.StatusDashboard` | 周期 snapshot 发布状态 | dashboard 进程拥有刷新循环和最后一次 snapshot。 |
| `SymphonyElixir.PRReview.Queue` | review dispatch/reconciliation 状态 | 命名 queue 串行化 claim 和恢复。 |
| `SymphonyElixir.EnvironmentFailureCircuit` | failure fingerprints 和 open state | 命名进程拥有跨 issue 的时间窗口。 |
| `SymphonyElixir.Linear.Health` | Linear 健康采样 | 命名 Agent 只拥有 diagnostics health state。 |
| `SymphonyElixir.Worker.Runtime` | worker poll/heartbeat 生命周期 | 命名 GenServer 拥有一个 worker runtime loop。 |
| `SymphonyElixir.Worker.HeartbeatMetrics` | 当前 heartbeat failure counters | 命名 Agent 拥有明确的内存 metrics state。 |
| `SymphonyElixir.Worker.HeartbeatHistory` | 合并中的 history write | 命名 GenServer 把持久化写入移出 heartbeat response path。 |
| `SymphonyElixir.Worker.AssignmentManager` | session liveness、assignment、lease 和 cancellation | 命名 GenServer 是 worker admission/lease 的唯一内存 owner。 |

新增跨调用可变状态必须进入拥有者明确的 OTP/启动边界；其他共享值通过参数或依赖注入传递。

## 锁定和外部假设

`mix.lock` 锁定 Hex 解算结果，`mise.toml` 固定 Erlang/Elixir，`.github/workflows/*.yml` 的 action
均使用完整 commit SHA。升级依赖、工具或 action 时，同一变更必须包含 lock/pin diff 和升级理由。
本次不修改依赖或 lockfile。

被审计为外部行为不确定的边界及其非 live 证据如下：

| 边界假设 | 契约测试 | 断言 |
| --- | --- | --- |
| Linear GraphQL 分页、错误 body 和 proxy options | `test/symphony_elixir/linear_client_test.exs` | 注入 request function，断言 query/variables、非 2xx typed error 和连接选项。 |
| GitHub CLI/REST lookup、create、mergeability 和失败类型 | `test/symphony_elixir/github_pull_request_test.exs` | 注入 command runner/HTTP function，断言精确请求与响应分类。 |
| worker-v1 Req transport 与 Panel HTTP contract | `test/symphony_elixir/worker/client_test.exs`, `test/symphony_elixir/worker/http_integration_test.exs` | 断言协议 id，并仅对进程内本地 endpoint 验证注册、claim、heartbeat 和 event。 |

PostgreSQL 存储集成由显式 `mix symphony.pg_smoke` 管理，不属于上述默认/离线核心入口；P-06 表中的
不确定远程协议测试均不访问 live 服务。

## P-01 至 P-06 审计矩阵

| 条款 | 改造前 | 改造前证据与理由 | 本次改动 | 改造后 | 可复跑证据 |
| --- | --- | --- | --- | --- | --- |
| P-01 | 部分满足 | `tracker.ex`/`linear/adapter.ex` 已隔离 Linear，但无全仓依赖分类或导入检查。 | 声明依赖角色和边界路径，增加 AST 引用检查。 | 满足 | `mix test test/symphony_elixir/dependency_boundary_governance_test.exs` |
| P-02 | 满足 | tracker、GitHub、worker 和 persistence provider 的必填输入均显式；上表未发现真实宽接口。 | 固化接口清单和一条常驻 review 规则。 | 满足 | 本文“对外接口审计”与 `git diff origin/main -- AGENTS.md` |
| P-03 | 部分满足 | default test 已关闭 Repo/HTTP，但 `scripts/unit.sh` 在测试前执行 `mix deps.get`，没有依赖准备后的离线入口。 | 增加 `scripts/core_test.sh` 并接入 unit chain。 | 满足 | `HEX_OFFLINE=1 scripts/core_test.sh` |
| P-04 | 部分满足 | 状态 owner 可定位，但无全仓核心写入 guard 或常驻注入规则。 | 声明 state owners，AST 检查全局写入，增加一条常驻规则。 | 满足 | governance test 的 global-write case |
| P-05 | 部分满足 | `mix.lock`、`mise.toml` 和 action SHA 已跟踪，但升级理由无常驻要求。 | 增加 lock/pin 与理由同变更规则；本票无依赖 diff。 | 满足 | `git ls-files --error-unmatch mix.lock mise.toml` 与 action `uses:` 静态审查 |
| P-06 | 满足 | Linear、GitHub、worker 已有注入或本地 endpoint 合同测试，但缺统一盘点。 | 固化外部假设表和一条常驻测试规则；无需新增 runtime injection。 | 满足 | 上表三个 test path 的定向测试 |

最终计数：符合 6，不符合 0，不适用 0，合计 6。

## 验证合同

```bash
mix test test/symphony_elixir/dependency_boundary_governance_test.exs \
  test/symphony_elixir/default_test_boundary_test.exs
HEX_OFFLINE=1 scripts/core_test.sh
mix test test/symphony_elixir/linear_client_test.exs \
  test/symphony_elixir/github_pull_request_test.exs \
  test/symphony_elixir/worker/client_test.exs \
  test/symphony_elixir/worker/http_integration_test.exs
mix docs.check && mix docs.drift && mix specs.check
scripts/check.sh && scripts/unit.sh && scripts/dialyzer.sh
git diff --unified=0 origin/main -- AGENTS.md
```

最后一条 diff 应只显示 P-02/P-04/P-05/P-06 对应的 4 个新增非空常驻规则行。上述命令均不要求
容器引擎；本合同不包含镜像级验证。
