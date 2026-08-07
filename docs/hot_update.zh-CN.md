# Symphony 热更新说明

本文说明 Symphony 当前可以做到哪些“热更新”，哪些只是 Elixir/OTP 理论能力，以及如果后续要支持真正不停机代码升级需要补哪些工程能力。

## 结论

Symphony 需要区分三种热更新：

| 类型 | 当前状态 | 说明 |
| --- | --- | --- |
| Settings / workflow 配置热更新 | 已支持 | 通过 Web UI 保存新的 SQLite active workflow version，运行时重新读取配置，不需要重启进程。 |
| 开发期代码热更新 | 部分支持 | Elixir VM 支持加载新 beam；当前 `bin/symphony` 不是 Phoenix dev server，代码改动通常需要重启，或在 `iex -S mix` 中手动 `recompile()`。 |
| 生产期 OTP release 热代码升级 | 未支持 | BEAM 支持 hot code upgrade，但本项目还没有 release upgrade、appup/relup、进程状态迁移和发布流程。当前生产策略应是重启式部署。 |

因此，当前可依赖的是“运行时配置热更新”，不是“任意代码不停机替换”。

## 1. 配置热更新：当前主要能力

Symphony 的长期运行配置来自 SQLite active workflow version。Settings 页面保存 Workflow 或 Agents 时，会写入新的 `workflow_versions` 记录并激活它。

关键路径：

- `/settings/workflow` 保存 workflow/routing/runtime 共享配置。
- `/settings/agents` 保存 base prompt、profiles、allowed updates 和 executor policy。
- 保存成功后调用 `WorkflowStore.force_reload/0`。
- `WorkflowStore` 也会每 1 秒轮询一次 active workflow version。
- `Config.settings/0`、Linear diagnostics、agent runner 和 orchestrator 读取当前 active workflow。

这意味着以下改动可以不重启服务：

- active states / terminal states / human review states。
- allowed transitions。
- profile prompt。
- profile allowed updates。
- executor type。
- workspace root。
- hook commands。
- Codex command 和部分 Codex runtime policy。
- polling interval 等 workflow contract 字段。

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
- Workflow 页面：保存 workflow state model、hooks、workspace、codex 等共享 workflow 字段。
- Agents 页面：保存 prompt 和 profile 设置。

保存成功后，页面会显示 saved 反馈；Linear 相关配置建议再打开 `/diagnostics/linear` 验证。

## 3. 运行中任务如何受影响

配置热更新不是回滚或改写已经启动的 run。

推荐语义：

- 新保存的 workflow version 影响后续读取配置、后续 dispatch 和后续 agent run。
- 已经创建的 run 应记录当时绑定的 workflow version，便于审计。
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
- 依赖数据库保存 run、event、workflow version 和 issue 快照来恢复可观测上下文。
- 如果未来引入 worker runtime，优先做到 worker 可下线、任务 lease 可过期/重领，而不是先做 BEAM hot upgrade。

## 7. 后续演进方向

如果以后要增强“热更新”，建议按以下顺序推进：

1. 完善配置热更新：所有 runtime contract 字段都能从 Settings 保存、校验、审计、恢复。
2. 明确 running run 的配置绑定语义：每个 run 固定引用启动时的 workflow version。
3. 增加 graceful pause / drain：暂停新任务，等待当前 run 完成或主动停止。
4. 支持重启式零丢失部署：进程重启后能从 DB 恢复 dashboard、队列和任务状态。
5. 最后再评估 OTP release hot upgrade：只有当重启式部署不能满足需求时再做。
