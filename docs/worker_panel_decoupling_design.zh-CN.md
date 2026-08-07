# Panel / Worker 解耦设计

## 1. 背景

当前 Symphony 的 Phoenix 服务同时承担控制面和执行面职责：

- 读取 tracker。
- 创建和维护 run 状态。
- 管理 workflow 配置。
- 启动本地 Codex 执行流程。
- 提供 dashboard 和 API。
- 写入 SQLite 运行历史。

这个结构适合早期实现，但长期会把 Web 服务、数据库、调度和实际执行绑在同一个运行边界里。后续需要把系统拆成：

- **Panel**：Elixir/Phoenix 服务，负责配置、调度、持久化、dashboard、审计和 operator control。
- **Worker**：外部执行进程，主动连接 Panel、领取任务、执行任务并回传状态。生产 worker 按目前技术方向使用 Rust 实现。

本设计文档描述当前仓库的 **Panel / 服务端设计**。其中 Panel 侧数据模型、worker
registration、task claim、heartbeat/lease、task event 上报、dashboard worker 页面，以及
`SYMPHONY_EXECUTION_MODE=worker` 入队路径已经在 Elixir 仓库中落地。Rust worker 的内部实现
不在本文范围内，但 Panel 协议必须足够稳定，让 Rust worker 可以独立开发。

## 2. 设计目标

- Worker 主动连接 Panel，Panel 不需要主动 SSH 或反连到 worker 机器。
- Panel 通过稳定 HTTP/JSON 协议和 worker 通信。
- Panel 负责 worker identity、session、token、task、lease、heartbeat 和事件持久化。
- Worker 只能完成自己持有有效 lease 的任务。
- Panel 重启后可以从 SQLite 恢复 worker/task/lease 状态。
- Worker 崩溃或断网后，lease 可以过期并按 retry policy 重新排队。
- Dashboard 可以展示 worker 在线状态、活跃 lease、任务队列、失败、取消和历史事件。
- 长期支持集中式部署和 worker 部署两种模式；不会在 worker API 出现后立刻强制切换到 worker-only。
- 保留当前 in-process execution 兼容路径；当前默认仍是 `centralized`，显式设置
  `SYMPHONY_EXECUTION_MODE=worker` 时才切换为外部 worker task 队列。

## 3. 非目标

- 不在 Elixir 仓库实现生产 Rust worker。
- 不设计 Rust worker 内部 workspace、sandbox、Codex runner 的完整细节。
- 不要求 Kubernetes、service mesh 或分布式数据库。
- 不把 UI 拆成独立 Node 前端。
- 不在第一阶段做公网 worker federation 或多租户权限模型。
- 不把 worker capability 当成安全权限；它只是调度提示。

## 4. 总体架构

```text
Tracker / Web UI
      |
      v
Panel: Phoenix + Ecto + SQLite
├── Project / Workflow / Tracker Config
├── Scheduler
├── Task Queue
├── Worker Registry
├── Lease Manager
├── Runs / Agent Turns / Events
├── Dashboard
└── Worker API / Protocol Contract
      ^
      |
      | worker 主动发起 HTTP/JSON 请求
      |
Rust Worker Runtime
├── Handshake client
├── Heartbeat loop
├── Task claim loop
├── Workspace manager
├── Codex runner
├── Hook runner
└── Result reporter
```

Panel 必须从一开始就把 worker 当成外部协议客户端。测试可以写 fake worker，但 fake worker 应该走 HTTP/JSON API，而不是 import Panel 内部模块。

## 4.1 部署模式

系统需要长期支持至少两种部署模式：

```text
centralized
  单个 Phoenix Panel 进程同时负责控制面和本地执行。
  适合开发、小规模可信环境、低运维成本部署。

worker
  Phoenix Panel 只负责控制面，Rust worker 负责执行。
  适合需要隔离、远程执行、多机器执行或更强资源边界的部署。
```

当前代码通过 `SYMPHONY_EXECUTION_MODE` 在 `centralized` 和 `worker` 之间全局切换。后续可以评估
`hybrid` 模式：同一个 Panel 同时允许部分 project 使用集中式执行，部分 project 使用 worker
执行。但当前要求是 execution mode 显式配置，并且 worker 功能不会破坏 centralized 默认路径。

## 5. Panel 责任边界

Panel 负责：

- 保存项目、tracker、workflow version 和运行配置。
- 根据 tracker 状态创建 run/task。
- 保存 worker identity、session、credential metadata。
- 验证 worker token 和协议版本。
- 根据 capability、project 状态、retry/backoff 和 concurrency 分配任务。
- 创建和续期 task lease。
- 接收 worker 进度、结果、日志和 artifact metadata。
- 在 dashboard 展示 worker、task、lease 和事件。
- 处理 operator 发起的 cancel/requeue 操作。

Panel 不负责：

- 在远程机器上启动 worker。
- 直接访问 worker 的本地 workspace。
- 直接执行 Codex 子进程。
- 信任 worker 上报的路径、日志或 capability。

## 6. Worker 责任边界

Rust worker 负责：

- 使用 bootstrap config 连接 Panel。
- 完成注册和握手。
- 定期 heartbeat。
- 根据自身空闲 slot 领取任务。
- 在本地准备 workspace。
- 执行 hook / Codex / cleanup。
- 持续回传状态事件。
- 在 lease 有效期内提交完成、失败或取消结果。

Rust worker 不拥有 workflow 配置来源。workflow 由 Panel 管理和版本化，worker 只消费任务 payload 或 workflow version 引用。

## 7. 握手机制

### 7.1 Bootstrap 配置

Worker 启动时只需要最小配置：

```text
PANEL_URL
WORKER_NAME
WORKER_TOKEN 或 WORKER_REGISTRATION_TOKEN
WORKER_LABELS
WORKER_CONCURRENCY
WORKSPACE_ROOT
SUPPORTED_EXECUTION_MODES
```

这些配置用于连接 Panel 和声明能力，不包含完整项目 workflow。

### 7.2 注册请求

Worker 启动后请求：

```http
POST /api/worker/v1/register
```

请求体：

```json
{
  "worker_name": "mac-mini-01",
  "worker_version": "0.1.0",
  "protocol_version": "worker-api-v1",
  "instance_id": "generated-boot-id",
  "labels": ["local", "macos", "trusted"],
  "capabilities": {
    "os": "darwin",
    "arch": "arm64",
    "sandbox": ["local"],
    "max_concurrency": 2,
    "supports_streaming_logs": true,
    "supports_workspace_cleanup": true
  }
}
```

响应：

```json
{
  "worker_id": "wrk_...",
  "session_id": "wss_...",
  "heartbeat_interval_seconds": 10,
  "lease_duration_seconds": 60,
  "server_time": "2026-05-01T00:00:00Z",
  "accepted_protocol_version": "worker-api-v1"
}
```

### 7.3 认证

第一版使用预共享 worker registration token：

- token 由 Panel 创建。
- worker 通过环境变量或本地 secret 文件读取。
- Panel 只保存 token hash 或 secret reference。
- UI 创建后不再展示完整 token。
- worker API 即使在 dashboard auth 关闭时也必须认证。

后续可以增加：

- 每个 worker 独立 rotated token。
- 注册后短期 session token。
- mTLS。
- 按 project / capability 限定 token scope。

### 7.4 协议版本

每个 worker 请求都带协议版本：

```text
X-Symphony-Worker-Protocol: worker-api-v1
X-Symphony-Worker-ID: wrk_...
X-Symphony-Worker-Session: wss_...
```

Panel 对不兼容版本返回明确错误，并记录 worker protocol event。

### 7.5 幂等性

worker 重启后应能用同一个 `WORKER_NAME` 或 stable identity 重新注册。Panel 需要区分：

- stable worker identity
- 当前 worker session
- 历史 sessions

这样不会因为进程重启不断创建新的逻辑 worker。

## 8. 任务领取和租约

Worker 完成握手后，通过 claim API 领取任务：

```http
POST /api/worker/v1/tasks/claim
```

请求体：

```json
{
  "worker_id": "wrk_...",
  "session_id": "wss_...",
  "available_slots": 1,
  "capabilities": {
    "labels": ["local", "macos"],
    "sandbox": ["local"]
  }
}
```

有任务时返回：

```json
{
  "task_id": "tsk_...",
  "lease_id": "lse_...",
  "lease_expires_at": "2026-05-01T00:01:00Z",
  "project_id": "prj_...",
  "run_id": "run_...",
  "workflow_version_id": "wfv_...",
  "issue": {
    "identifier": "ABC-123",
    "title": "Fix flaky retry handling"
  },
  "execution": {
    "workspace_policy": {},
    "codex_command": ["codex"],
    "hooks": {},
    "prompt": "..."
  }
}
```

无任务时返回：

```json
{
  "task": null,
  "poll_after_seconds": 5
}
```

租约规则：

- 一个 task 同一时间只能有一个 active lease。
- lease 有过期时间。
- worker 通过 heartbeat 或显式 renew 续租。
- worker 只能完成自己当前持有 active lease 的 task。
- lease 过期后，Panel 可以按 retry policy 重新排队。
- lease 过期后的 completion 应被拒绝，或记录为 late completion 但不改变 run 的终态。
- claim 和 lease 创建必须在数据库事务里完成。

## 9. Heartbeat 和取消

Worker 定期发送：

```http
POST /api/worker/v1/heartbeat
```

请求体：

```json
{
  "worker_id": "wrk_...",
  "session_id": "wss_...",
  "active_leases": ["lse_..."],
  "available_slots": 1,
  "resource_snapshot": {
    "load_average": 1.2,
    "disk_free_bytes": 1234567890
  }
}
```

响应：

```json
{
  "ok": true,
  "server_time": "2026-05-01T00:00:10Z",
  "lease_renewals": [
    {
      "lease_id": "lse_...",
      "lease_expires_at": "2026-05-01T00:01:10Z"
    }
  ],
  "commands": []
}
```

Panel 可以通过 heartbeat response 下发协作式命令：

```json
{
  "commands": [
    {
      "type": "cancel_task",
      "task_id": "tsk_...",
      "reason": "operator_requested"
    }
  ]
}
```

Worker 收到取消后应：

- 停止领取新任务。
- 尽量停止当前 Codex 进程。
- 执行安全 cleanup。
- 回传 `task.cancelled` 或 `task.failed`。

## 10. 结果和事件回传

Worker 通过任务事件 API 回传状态：

```http
POST /api/worker/v1/tasks/:task_id/events
```

典型事件：

- `task.accepted`
- `workspace.preparing`
- `workspace.ready`
- `hook.started`
- `hook.finished`
- `codex.started`
- `codex.turn.started`
- `codex.turn.finished`
- `task.completed`
- `task.failed`
- `task.cancelled`

Panel 写入统一 events 表，并同步更新 runs、agent_turns、workspaces 或 task 状态。Dashboard 和 API 都从持久化状态读取，不依赖 worker 进程内存。

## 11. 数据模型

建议新增或扩展以下表：

```text
workers
├── id
├── name
├── status
├── labels_json
├── capabilities_json
├── credential_ref
├── last_seen_at
├── inserted_at
└── updated_at

worker_sessions
├── id
├── worker_id
├── protocol_version
├── worker_version
├── instance_id
├── connected_at
├── last_heartbeat_at
├── disconnected_at
└── status

tasks
├── id
├── project_id
├── run_id
├── workflow_version_id
├── status
├── priority
├── required_capabilities_json
├── payload_json
├── inserted_at
└── updated_at

task_leases
├── id
├── task_id
├── worker_id
├── worker_session_id
├── status
├── attempt
├── expires_at
├── acquired_at
├── released_at
└── updated_at
```

已有 `runs`、`agent_turns`、`workspaces`、`events` 继续作为 operator-facing history。`tasks` 和 `task_leases` 是调度和执行合同。

## 12. 调度规则

第一版调度保持保守：

- project 必须 enabled。
- workflow version 必须存在且可执行。
- run 不在 terminal state。
- retry/backoff 未到期的 task 不分配。
- 按 worker max concurrency 限制分配。
- 按 required labels/capabilities 匹配 worker。
- 同一个 issue 默认不并发分配多个 active task。
- 所有 claim 决策在数据库事务内完成。

后续再考虑 priority、公平调度、worker pool、跨 project 限流。

## 13. 失败处理

- Worker 无法注册：返回明确错误，worker 自行 backoff retry。
- 协议版本不兼容：拒绝请求并记录事件。
- Worker 断网：heartbeat 超时，session offline，active lease 进入 stale/expired 流程。
- Worker 崩溃：lease 过期后 task 可按 retry policy 重新排队。
- Panel 重启：从 DB 恢复 worker/session/task/lease 状态，worker 重新注册。
- 重复 claim：如果 idempotency key 相同，返回已有 lease；否则按当前任务状态拒绝或返回无任务。
- 重复 completion：返回已记录终态。
- late completion：记录审计事件，但不覆盖当前 run/task 终态。

## 14. Dashboard 需求

Panel UI 需要增加：

- Workers 列表。
- Worker detail。
- Worker sessions。
- Online/offline/last_seen 状态。
- Active leases。
- Queued/running/expired/completed tasks。
- Worker event timeline。
- Cancel/requeue controls。
- Worker token 创建和轮换 metadata。

这些页面继续使用 Phoenix LiveView，不引入独立 Node 前端。

## 15. 演进路线

这不是一个 exec plan，需要拆成多个后续计划：

1. Panel worker/task/lease 数据模型和 migration。
2. Worker registration、credential 和 handshake API。
3. Task queue、capability matching 和 lease acquisition API。
4. Heartbeat、lease renewal、expiry 和 cancellation。
5. Worker result/event reporting API。
6. Scheduler 和现有 orchestrator 集成，并显式支持 centralized / worker execution mode。
7. Dashboard worker/task/lease 页面。
8. Rust worker 接入后，提供受控切换路径；集中式部署继续作为受支持模式保留。

## 16. 开放问题

- 第一版 worker API 使用纯 HTTP polling，还是 heartbeat 使用 long-polling？
- worker token 是全局 registration token，还是先做 per-worker token？
- task payload 是否直接包含完整 prompt，还是只包含 workflow version id 并由 worker 单独拉取？
- 日志内容直接入库、写文件后只入库 metadata，还是两者混合？
- Rust worker 仓库和 Panel 仓库之间如何同步 API fixture？
- in-process execution 兼容路径保留多久？

## 17. 结论

Panel / Worker 解耦的核心是把 Symphony 的执行从“Panel 直接跑本地任务”改为“Panel 持久化任务并通过租约分配给外部 worker”。

当前 Elixir 仓库已经优先落地 Panel 侧能力：协议、认证、任务队列、租约、心跳、结果回传、dashboard 和兼容迁移。Rust worker 作为独立执行面，通过稳定 HTTP/JSON 协议接入。
