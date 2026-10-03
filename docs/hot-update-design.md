---
title: Symphony 热更新说明
genre: design
domain: [hot-update, runtime]
status: current
language: zh-CN
updated: 2026-09-23
design_status: landed
---

# Symphony 热更新说明

本文说明 Symphony 当前可以做到哪些“热更新”，哪些只是 Elixir/OTP 理论能力，以及如果后续要支持真正不停机代码升级需要补哪些工程能力。

## 结论

Symphony 需要区分三种热更新：

| 类型 | 当前状态 | 说明 |
| --- | --- | --- |
| Settings / workflow 配置热更新 | 已支持 | instance singleton 或 project slice 保存后重新组合并原子发布所有 enabled projects，不需要重启进程。 |
| 开发期代码热更新 | 部分支持 | Elixir VM 支持加载新 beam；当前 `bin/symphony` 不是 Phoenix dev server，代码改动通常需要重启，或在 `iex -S mix` 中手动 `recompile()`。 |
| 生产期 OTP release 热代码升级 | 未支持 | BEAM 支持 hot code upgrade，但本项目还没有 release upgrade、appup/relup、进程状态迁移和发布流程。当前生产策略应是重启式部署。 |

因此，当前可依赖的是“运行时配置热更新”，不是“任意代码不停机替换”。

## 1. 配置热更新：当前主要能力

Symphony 的长期运行配置来自固定 `app_settings["instance_workflow"]` 与每项目唯一的 PostgreSQL
`workflows` slice。portable package 导入在同一事务内写两个 scope；单独保存任一 scope 后，
`WorkflowStore` 都重新读取 singleton 与全部 enabled project slices，并一次替换完整内存 snapshot。

关键路径：

- `/settings/import` 导入 combined portable package，并拆分为 instance/project durable scopes。
- base prompt、profiles 与 Runtime workspace/hooks/Codex selectors 属于 instance singleton。
  Agents/Runtime 直接保存 singleton，不要求 project，也不随 project selector 改变。Projects form 只包含
  tracker/repository/source/setup/cleanup，因此 project save 不会提交或改变 instance 字段。
- Runtime model/effort 可选集来自 `SymphonyElixir.Codex.ModelCatalog`。该 code-owned catalog
  与 `Dockerfile` 的 exact bundled `CODEX_VERSION` pin（当前 `0.156.0`）同步派生；升级 CLI
  需要重建镜像并同步 catalog。从 Runtime 或 Import 保存当前 catalog 的值属于 workflow 配置热更新。
- 保存成功后，持久化边界在返回成功前发布所有 project 的完整 derived snapshot；发布失败会返回显式错误，页面不会误报 runtime refreshed。
- `WorkflowStore` 以固定的内部节奏启动至多一个后台刷新任务来检测外部 activation。刷新期间读取继续使用
  last-known-good snapshot，timer tick 不累积；generation guard 会丢弃早于新 mutation 的结果。
- `Config.settings/0`、Linear diagnostics、agent runner 和 orchestrator 读取当前 active workflow。

四个 `WorkflowStore` 读取 API 都只读取原子替换的内存 snapshot，不访问 PostgreSQL，也不等待后台任务。

这意味着以下改动可以不重启服务：

- project tracker active states / terminal states。
- profile prompt。
- profile allowed updates。
- executor type。
- workspace root。
- hook commands。
- Codex app-server launch command、`codex.model`、`codex.reasoning_effort` 和部分 Codex runtime policy；
  model/effort 只由结构化 selector 拥有，launch command 不能通过 CLI option 覆盖它们。
- polling interval 等 workflow contract 字段。

`workflow.states`、transitions、human review states 与 tool policy 是 code-owned，不属于热更新持久化状态。

保存后如果配置能解析但语义不完整，Settings 会显示 `Configuration check failed`。这类错误不会阻止保存，但会让 runtime 保持不可监听或不可调度，直到配置修好。

## 2. 配置热更新的使用方式

启动 dashboard：

```bash
cd elixir
mise exec -- ./bin/symphony --port 4000
```

打开：

```text
http://127.0.0.1:4000/settings
```

修改配置后点击对应页面的保存按钮：

- Projects 页面：保存 project 字段，例如 Linear project slug、repository URL、default branch。
- Agents 页面：保存 installation-wide base prompt 与 profiles。
- Runtime 页面：保存 installation-wide workspace、hooks 与 Codex selectors。
- Import 页面：分组预览 singleton 与显式选择的 project slice；combined confirm 原子写两个 scope。

保存成功后，页面会显示 saved 反馈；Linear 相关配置建议再打开 `/diagnostics/linear` 验证。

## 3. 运行中任务如何受影响

配置热更新不是回滚或改写已经启动的 run。

推荐语义：

- 新保存的 workflow 影响后续读取配置、后续 dispatch、retry、resumed turn 和 operator task。
- 已执行中的 turn 可使用已接收的输入完成；下一安全执行边界重新解析当前 workflow。
- `codex.model` 与 `codex.reasoning_effort` 是 model/effort 唯一的 workflow authority，并作为 Codex
  `turn/start` override 发送。model 未配置时使用 Codex 默认 model；effort 未配置时使用所选 model
  或 Codex 的默认 effort。`codex.command` 只启动 app-server，schema 禁止它通过 `-c` / `--config`
  的 `model` / `model_reasoning_effort` 或 `-m` / `--model` 建立第二份 authority。显式 selector 只影响
  后续 turn/session，不改写已经启动的 turn。
- Runtime selector 与 workflow validation 读取同一个 `ModelCatalog`，因此页面可选的
  model/effort 组合与 bundled CLI pin 对应的 code-owned 快照保持一致。Runtime 或 Import 持久化后，
  Runtime 显示该值，后续 turn/session 才读取并发送对应 override。
- worker claim 每次从最新 workflow 构造 ephemeral payload；不存在尚未 claim 的 persisted task，
  payload 会携带当次 snapshot 中的 Codex model/effort selector；已发放的当前 assignment
  不在保存时改写。
- 已经启动的 Codex turn 不应被中途替换 prompt；下一次调度或下一次 run 才应使用新配置。
- 如果新配置不通过 runtime validation，orchestrator 应停止监听或调度，而不是继续用旧配置假装成功。

这也是为什么 Settings 保存后仍需要 diagnostics 和 configuration check：保存表示“进度已持久化”，不表示“运行时已经可以安全监听”。

## 4. 开发期代码热更新

Elixir/BEAM 可以在 VM 中加载新编译的模块，但当前项目的本地启动方式是：

```bash
mise exec -- ./bin/symphony --port 4000
```

`bin/symphony` 内部执行的是：

```bash
mix run --no-start -e 'SymphonyElixir.CLI.main(System.argv())'
```

这不是 Phoenix 默认的 `mix phx.server` 开发模式，也没有配置 `Phoenix.LiveReloader`。因此，当前最可靠的代码开发循环是：

```bash
# 停止当前进程
Ctrl-C

# 重新启动
mise exec -- ./bin/symphony --port 4000
```

如果需要在同一个 VM 中临时试验模块热加载，可以用 IEx：

```bash
mise exec -- iex -S mix
```

然后手动启动或调用需要的模块，并在修改代码后执行：

```elixir
recompile()
```

这只适合开发调试。它不会自动迁移长期运行的 GenServer state，也不等同于生产热升级。

## 5. 为什么不直接承诺生产热代码升级

BEAM 支持同时保留旧版和新版模块代码，也支持 release hot upgrade。但要把它变成可靠生产能力，需要额外设计：

- 使用 Mix release 或 release 工具链发布版本。
- 为需要迁移状态的 GenServer 编写 `code_change/3`。
- 生成并测试 appup/relup。
- 定义数据库 migration 和代码升级的顺序。
- 处理 LiveView、Endpoint、Repo、Orchestrator、Worker session、Task lease 等长期进程的状态兼容。
- 设计失败回滚策略。

Symphony 当前仍处于 alpha 阶段，配置模型和 UI 还在变化。此时优先做 release hot upgrade 会增加大量兼容成本，收益不高。

## 6. 推荐部署策略

当前推荐：

- 配置变更走 Settings，不重启。
- 代码变更走重启式部署。
- 重启前确保没有需要保护的本地 workspace 操作正在进行。
- 依赖数据库保存 run、event、当前 workflow 和 issue 快照来恢复可观测上下文。
- 如果未来引入 worker runtime，优先做到 worker 可下线、任务 lease 可过期/重领，而不是先做 BEAM hot upgrade。

## 7. 后续演进方向

如果以后要增强“热更新”，建议按以下顺序推进：

1. 完善配置热更新：所有 runtime contract 字段都能从 Settings 保存、校验、审计、恢复。
2. running turn 使用已经接收的输入完成，后续 turn 从发布的 current-workflow snapshot 重新解析配置。
3. 增加 graceful pause / drain：暂停新任务，等待当前 run 完成或主动停止。
4. 支持重启式零丢失部署：进程重启后能从 DB 恢复 dashboard、队列和任务状态。
5. 最后再评估 OTP release hot upgrade：只有当重启式部署不能满足需求时再做。
