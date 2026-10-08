---
title: Repository Verification Design
genre: design
domain: [governance, testing, verification]
status: current
language: zh-CN
updated: 2026-10-08
design_status: landed
---

# 仓库验证设计

## 所有权与边界

本变更前 V 组没有 L3 owner。本文登记为 V-01 至 V-09 的唯一 owner，拥有初始化入口、
完整门禁 runner、测试确定性及 HTTP 禁外网守卫和前后审计。
[面向 Agent 的代码设计](agent-facing-code-design.md)继续拥有 `mix agent_code.check` 的输出、
阈值、豁免、门禁接入地位与全量门禁时长标定。runner 不复制检查器 finding JSON，
10 分钟仅为观察预算，不改变 `record_only` 或新增硬阈值。
[文档体系设计](documentation-system-design.md)继续拥有 D 组入口一致性检查。
无产品配置、数据库、部署拓扑或人工验证流程变更。

## 初始化与完整门禁

仅需预装 mise，执行 `scripts/setup.sh`：信任本仓工具声明、安装声明工具、非交互安装
Hex/Rebar、执行现有 `mix setup`。Erlang 从浮动主版本 `28` 收紧为本机已验证的 `28.5`，
原因是干净 checkout 的可重复初始化；Elixir 仍为 `1.19.5-otp-28`，Mix 依赖仍由原 `mix.lock`
锁定。重复执行不更新 tracked files。工具和依赖下载属于初始化，不属于测试出站请求。

唯一完整入口 `scripts/quality.sh` 通过 mise 启动其内部 Elixir runner；runner 顺序调用
原 `scripts/check.sh`、`scripts/unit.sh`、`scripts/dialyzer.sh`，即使一项失败仍收集其余结果。
不复制子 gate 实现。正常终端每 gate 一行 JSON，最后一行总摘要，均包含毫秒耗时。
完整 stdout/stderr 写入 `_build/quality/<microseconds>-<pid>/<gate>.log`，每次执行独立保留，
同目录 `summary.json` 包含 `status`、`duration`、`duration_unit`、`gates`。
每个 gate 有 `gate`、`status`、`duration`、绝对 `log_path`。
失败附加 `violation: "gate_failed"`、`actual: {exit_code: N}`、`expected: {exit_code: 0}`；
原始 ExUnit expected/actual 差异保留在该日志中。runner 不尝试解释各工具的断言格式。
全部通过返回 0，否则返回 1；warning 是日志内容，不具有专用退出码。
CI 执行同一初始化/完整入口，并在 `always()` 步骤上传 `_build/quality/`。
新增 upload-artifact 固定到 v4 的 `ea165f8d65b6e75b540449e92b4886f43607fa02`，用于保留失败证据。

文件/行号和标签选择仍直接使用 ExUnit，不经过完整 runner：

```bash
mise exec -- mix test test/symphony_elixir/repository_verification_test.exs
mise exec -- mix test test/symphony_elixir/repository_verification_test.exs:7
mise exec -- mix test test/symphony_elixir/repository_verification_test.exs --only verification_selection
scripts/quality.sh
```

## 测试出站边界

`test/test_helper.exs` 在应用重启前为 Req 安装测试专用 `finch_request`。
现有 Linear、GitHub 和 worker 客户端均使用 Req，守卫在 DNS/连接前检查目标，仅允许字面
`127.0.0.1`/`::1`；不信任可解析为其他地址的主机名。拒绝抛出包含 violation、actual、
expected 的错误，不能转换为成功响应。真实 loopback TCP 服务正例和外部主机负例验证边界。
测试共享 workflow 默认使用 `http://127.0.0.1:1/graphql`，意外请求不能再触达 Linear。
显式 `SYMPHONY_RUN_LIVE_E2E=1` 保留已有人工 E2E 通道；默认完整入口不设置此变量或调用 E2E。
ExUnit seed 固定为 0，可用显式 `mix test --seed N` 复现其他顺序。

## 历史审计（不追溯改写）

“部分满足”不计入符合；以下为任务提供的历史证据，不冒充本次重新执行。

| 日期 / commit | 满足 | 部分满足 | 不满足 | 可复核依据 |
| --- | --- | --- | --- | --- |
| 2026-09-22 / `bb155d8` | 5 | 2 | 2 | 保留原历史结论；用 `git show bb155d8:AGENTS.md` 与 `git ls-tree bb155d8 scripts/` 核对入口。任务未提供逐条判定，不推造。 |
| 2026-09-25 / `a24b732` | 4 | 3 | 2 | 两次 `mix setup` 返回 0，第二次依赖 unchanged；`git diff --exit-code` 返回 0。 |
| 2026-09-26 / `9e4ba10` | 4 | 3 | 2 | `scripts/unit.sh`：1100 tests、2 skipped，但出现 Linear 401；尚无 setup/runner JSON/guard。 |

`a24b732` 与 `9e4ba10` 的逐项判定：V-01 部分，V-02 满足，V-03 满足，V-04 不满足，
V-05 不满足，V-06 部分，V-07 满足，V-08 满足，V-09 部分。
V-03 原命令 `mix test test/symphony_elixir_web/admin/observability_presenter_test.exs:6`：
1 test、2 excluded。V-09 原人工样本为 177.831s 与 68.144s。
SYM-137 / `90fc3d2` 已将 `orchestrator_multi_project_test.exs:359` 原有 suspend 与
`Process.sleep(5_100)` 改为消息握手，本变更不修改该用例。

## 本次确定性审计与验证记录

基准 commit：`337aef3c097dd58db92a315454031131e5b8a771`，2026-10-08 工作树变更。
环境：macOS、Erlang 28.5、Elixir 1.19.5 / OTP 28。最终执行结果见下文验证记录。
审计命令：`rg -n 'Process.sleep|utc_now|monotonic_time|system_time|:rand|Enum.random|Enum.shuffle|strong_rand' test lib`。

- 默认测试中未发现显式 `:rand`、`Enum.random`、`Enum.shuffle` 或 `strong_rand`；ExUnit 顺序用固定 seed。
- `System.unique_integer`、`make_ref` 用于临时目录、消息 token 和 fixture 标识，不比较随机数值。
- 展示、事件、持久化 fixture 的 `utc_now` 仅构造同源记录；纯策略测试已有固定日期或 `now` 入参。
- `Process.sleep(:infinity)` 是待终止进程；带截止期限的重试读取是同步等待，不以等待秒数证明业务成功。
- 重试用例核对精确的调度延迟日志和状态；移除读取两次单调时钟之差的脆弱窗口。
  core/status/worker terminal 的延迟计算同时有纯策略测试覆盖，状态观察使用消息顺序屏障。
- worker claim 测试向 AssignmentManager 注入捕获一次的 `now`，精确断言到期值；
  重启用例通过 ExUnit supervisor 的同步停止确认退出。reconciliation 等待拥有任务的完成状态。
- worker 与 HTTP 的慢 reconciliation 使用显式 release 握手；heartbeat 合并测试取消真实计时器，
  显式发送 flush。snapshot 超时 stub 明确不回复，结果不再取决于一个 25ms sleep 是否先结束。
- dashboard refresh 与 worker terminal 重试用例使用 `:sys.get_state` 消息屏障；
  stall 测试直接触发 poll，等待 monitor DOWN；SYM-137 用例保持不动。
- 剩余 `Process.sleep` 仅位于有上限的状态轮询或无限等待的待终止 fixture。
  polling 的超时仅防止挂死，业务成功取决于谓词/消息，不取决于睡满某个毫秒数。
  shell/HTTP/GenServer 的超时边界测试使用明确的无响应 stub、配置时限或 release 消息；
  这些边界的安全超时不作为业务时钟输入。runner 的真实耗时只记录观察值。
- 事件/展示 fixture（`codex_update`、`dashboard_signal`、`extensions`、`worker_terminal_outcome`、
  `merge_conflict_reconciler`、`persistence/run_pagination`、`*_presenter`、`observability_*`、
  `settings_fake_persistence`）只比较同源时间戳、顺序或形状；不机械替换这些值。
  analytics 用例的明确窗口/相对 fixture 与已有纯层 `now` 注入共同覆盖时间筛选。
- 发现并修复零项目 Settings 用例的清理竞态：先重置 fixture，再恢复 provider，防止后台刷新
  在两个不同 fixture 生命周期之间读取空项目。该修复不修改生产持久化或调度代码。

新增代码注释仅说明 V-08 安全边界；未移除或改写原有非显然意图注释。

## 改造后逐项审计

本次结论：**9 符合 / 0 不符合 / 0 不适用**。以下每条独立判定；不能用代码门禁通过替代
测试符合性审计。初始化快照提交只用于隔离验证，不是产品提交，也未修改当前分支提交历史。

| 条款 | 判定 | 本次可复跑证据 |
| --- | --- | --- |
| V-01 | 符合 | `scripts/setup.sh` 完成声明工具与锁定 Mix 依赖初始化；`scripts/quality.sh` 唯一聚合 check/unit/dialyzer，实际三项通过。 |
| V-02 | 符合 | 独立临时仓库快照 `83a0885a8854179f8b171cc9e1d2056421df1a0e`：连续两次 `scripts/setup.sh` 均 exit 0，每次 `git diff --exit-code` 为 0，最终 porcelain 为空；`evidence/setup.json` 与两份日志。 |
| V-03 | 符合 | `repository_verification_test.exs:7` 与 `--only verification_selection` 各 1 test、0 failures、5 excluded；该用例在最小 Mix fixture 中验证未选中失败用例被排除，且不运行 quality。 |
| V-04 | 符合 | runner 每 gate 一行、总计一行；真实 ExUnit 失败 fixture 保留 left 2/right 1，六个 runner/guard 测试全部通过；JSON 中每个日志路径存在。 |
| V-05 | 符合 | 默认 unit 启用 guard；外部域名/IP、localhost 名称、外部 proxy 负例与真实 loopback 服务正例通过。共享 Linear fixture 改为 loopback；完整 unit 无外部 Linear 401。时间/随机判定依据见上一节；引用 SYM-137 / `90fc3d2`，指定用例无 diff。 |
| V-06 | 符合 | 受控退出 7 的终端和 JSON 均断言 violation、actual.exit_code=7、expected.exit_code=0、log_path；真实 ExUnit 左右值留在日志；删除字段会使回归测试失败。 |
| V-07 | 符合 | runner fixture 成功（含 warning 文本）返回 0，任一失败返回 1；仍执行最后一个 gate 并保留日志，无 warning 退出码。 |
| V-08 | 符合 | setup 使用非交互 force/yes；unit 清除 live E2E opt-in，完整 runner/CI 静态回归排除人工入口；全程未执行容器、镜像、PostgreSQL smoke 或 live E2E。 |
| V-09 | 符合 | 成功样本 check 11.613s、unit 147.884s、dialyzer 9.449s、总计 168.961s；低于 600s 观察预算，仍仅 record_only。 |

成功样本产物目录：`_build/quality/1791416968020692-9853/`。其 `summary.json` 记录总结果与
三项 gate，`evidence/` 保存初始化、单点、标签、docs 与 specs 的补充证据。
unit 日志为 core 35 tests / 0 failures，加覆盖率 suite 1236 tests / 0 failures / 2 skipped，
覆盖率 86.95%。随后删除了一个仅重复检查 seed 配置的测试，用更有行为价值的 Mix 单点选择
fixture 保留同一入口；最终 repository verification 文件单独复核为 6 tests / 0 failures。

`mix docs.check`：48 passed、0 failed；`mix specs.check`：通过。
`mix docs.drift --format json` 已执行并保留机器报告，但 **exit 1**：原有
`docs/execution-worker-operations.md:166` 的 `SYMPHONY_PANEL_COOKIE_FILE` 定义在
`scripts/listening-off.sh`，不在 drift 检查器扫描的 `lib/` 或 `config/` 中。
该项不是本次 V 组引入的问题，不能标为通过；后续应由文档体系 owner 为脚本拥有的配置
登记可定位的取证规则。这里不扩大 D 组检查器范围或修改部署合同。
