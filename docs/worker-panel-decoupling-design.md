---
title: Panel / Worker Execution Design
genre: design
domain: [worker, architecture]
status: current
language: zh-CN
updated: 2026-09-12
design_status: landed
---

# Panel / Worker 执行设计

Linear 是“当前是否有工作”的唯一事实源。Panel 是唯一访问 Linear 的组件；worker 仅使用
register、claim、heartbeat 和 task event API。PostgreSQL 保存 worker/session 身份以及 run/event
历史，但不保存待执行工作。

`Worker.AssignmentManager` 是单 worker deployment 的 assignment/lease 所有者。它串行处理
claim，因此同一 Panel 实例同一时刻最多发布一个 assignment。每次 claim 都验证 session 为 online、
heartbeat 未超过 freshness cutoff 且调用方当次 `available_slots > 0`，再实时读取 Linear candidates，按 priority、created_at、identifier 排序，再按 issue id
读取 Linear 并重新验证状态、依赖、routing/profile 和未清除的持久 `blocking_decision`。Panel 创建新 run 和不可混淆 assignment id，
并从 `AgentRunner.Policy` 的唯一 profile-to-started-state 映射推导 worker 起始态：
`refinement` 使用 `Refining`，`implementation` 使用 `In Progress`。非 started issue 必须先按当前
workflow contract 验证并执行 `Todo -> Refining` 或 `Ready -> In Progress`；只有状态更新成功才返回当前
workflow 生成的 payload，返回的 assignment issue、payload issue 和 prompt 当前状态都使用该 started state。
同一成功 claim 同步把 assignment 注入 `Orchestrator` 当前态：`/api/v1/state` 的
`running` 行来自该内存 entry，包含 issue、run、worker、开始时间、session 和 Codex token
进度。该 feed 只是当前态投影，不创建队列或持久 lease；历史事实仍只写入 run/event。

历史去重门只把 worker started states 当作已启动态：`Refining` 和 `In Progress`。候选 issue 处于
这两个状态之一时，最新 worker run 必须是 `succeeded`、`failed` 或 `cancelled` 才能重新 claim；最新
worker run 仍是非终态时不得重复派发。默认 `tracker.active_states` 仍是 `Todo`、`Ready` 和
`In Progress`，不默认派发 `Refining`。

`total_slots` 是 session/deployment 的 advertised aggregate 观测值，不允许并行发放多个 assignment。
有效 admission capacity 仅在存在 fresh online advertised slot、调用方有 slot 且无当前 assignment 时为
1，否则为 0。没有合格 issue、已有 assignment、session 不新鲜或没有 slot 时返回 `{task: null}`，
并附带可测试的 structured admission reason（capacity 0/1 与拒绝原因）。若候选 issue 已有未清除的
`blocking_decision`，claim 返回 `admission.reason = blocking_decision`，并记录包含 issue、worker/session
和 blocking reason 的 `event=worker_claim_skip` 日志；这不同于状态不匹配、依赖阻塞、human review、run
history、capacity 或 session freshness 的拒绝。真正访问 tracker 后的连续空 claim 由
`AssignmentManager` 返回强制性的 `poll_after_seconds` 建议：首次为 5 秒，第 2 至 5 次
为 30 秒，第 6 次起为 60 秒并封顶。worker 必须按建议调度下一次 claim；为滚动升级兼容旧
Panel，字段缺失时回退 5 秒。持续空闲时新任务最多额外等待 60 秒。

Linear 429、5xx 或 request failure 会立即停止 workflow 遍历，不能被后续 workflow 的空结果
覆盖。首次连续错误建议 30 秒，后续错误建议 60 秒并封顶；HTTP 分别映射为 429 和 503，响应
顶层同时包含结构化 `error` 与 `poll_after_seconds`。tracker 再次成功会清除错误 streak，并把
该次空结果作为新的首次空 claim；成功 assignment 清除全部 streak。worker 在 claim client 的
内部重试耗尽后，对 HTTP 429/5xx 同样按 30、60 秒退避，任一成功 claim 清除该 HTTP failure
streak；401 仍执行既有 session recovery。

已有 assignment、没有 slot 或 session 不新鲜的快速路径不读取 Linear，也不改变 tracker streak。历史 run/event 和旧 payload
从不生成工作。协议继续把 assignment id 放在 `task_id` 与 `lease_id` 字段中以避免 worker 协议
迁移；correlation 同时包含 project、issue、run、worker/session 和 assignment id。

Assignment 只存在于 Panel 内存，包含当前 payload、worker/session、run、issue 和 expiry。
heartbeat 响应路径不等待 worker/session freshness 持久化。controller 完成 identity/protocol
解析后，`AssignmentManager.heartbeat/5` 先把 worker/session observation 交给
`Worker.HeartbeatHistory`；该进程按 worker/session 合并后异步调用 `heartbeat_worker/2`，其结果只服务
`/workers` freshness/audit history，失败只写日志，不改变本次 heartbeat 的 HTTP status、`Retry-After`、
`worker_api.heartbeat_failed_attempts` 或任何调度/repair 决策。没有提交 active lease 的 idle heartbeat
不进入 `AssignmentManager` 队列，直接返回成功和空续期列表。提交 active lease 的 heartbeat 只进入
`AssignmentManager` 的短临界区尝试续期；只有调用 session 持有当前 assignment、提交匹配 id 且 lease
未过期时才续期。该内存续期临界区未在 heartbeat 预算内完成时，worker-v1 API 返回 retryable 503，
稳定错误码为 `worker_heartbeat_unavailable`，响应包含正数 `retry_after_seconds` 和 `Retry-After`
header，且不包含 crash stack。该失败只计入内存 `worker_api.heartbeat_failed_attempts`，不创建 queued
work、新 assignment、failed run 或自动修复动作。
progress 或 terminal event 必须匹配当前未过期 assignment；不匹配、过期、Panel 重启前的旧 id 都返回明确冲突。
accepted/progress/completed/failed/cancelled 写入统一 `events` 并更新 `runs`。terminal event 终结
当前 assignment，不产生 queued work。未来执行必须来自新的 Linear fetch、未清除 blocking decision
检查、二次校验、新 run 和新 assignment。
accepted/progress 路径同时更新 `Orchestrator` 当前态：`task.progress` 携带
`codex_session_started` 或 Codex app-server 原始消息时，Panel 更新对应 running entry 的 session、
last event/message 和绝对 token delta；terminal event、取消、expiry 或 reconciliation 失败旧 run 时
移除 running entry，并将 ended runtime 计入聚合。`retrying` 与 `blocked` 仍由 Orchestrator
拥有：worker `failed` 结果在预算内进入 retry，预算耗尽或 `blocked` 结果进入持久 blocker。

terminal event 必须携带归一化的 `outcome`（`success` / `blocked` / `failed` / `cancelled`），由 worker 侧的
Codex adapter 判定，Panel 不得再按 reason 分类。Panel 只按该字段分流：`success` 与 `cancelled` 清理
该 issue 的失败链；`blocked` 立即持久化 blocking decision 并投递 Linear 评论与 `Blocked` 状态；
`failed` 消耗一次 `agent.max_failure_retries` 预算，耗尽后同样持久化 blocking decision。outcome
缺失或不在上述取值内按 `failed` 处理，协议异常不得绕过失败预算。
持久 decision 一旦存在，即使 Linear comment/state 写入失败且 tracker 仍返回 active state，后续 worker
claim 也必须停止认领；只有 `BlockingDecision.clear/1` 清除 decision 并重置 no-progress streak 后，issue
才可在状态、依赖、routing/profile 和 run-history 均通过时重新认领。
当 worker 内 Codex 命令执行能力不可用（例如 bwrap/user namespace 创建被拒）时，worker/Codex
adapter 必须快速产出同一 terminal `failed` outcome，并在 summary reason 中保留可区分原因；Panel
仍只按 `outcome` 路由，不把 assignment 留在 `In Progress` 等待 stall/turn timeout。

Panel 重启不会恢复 assignment 或旧 payload。reconciliation 读取 Linear `In Progress` issue 和
最新 worker run 时间：lease timeout 前保持不派发；超时后将僵尸 issue 转回 `Ready` 并失败终结
旧 run。回收判据不调用 session heartbeat 过期扫描，也不以 `worker_sessions.status` 或
`last_heartbeat_at` 作为僵尸回收准入。重启后到 worker 下一次 heartbeat/claim 前，Panel 将旧 session
视为未知而非死亡；这个窗口按 worker heartbeat interval 预算通常不超过 10 秒。未知窗口内不重新派发，
直到 run 级 lease 超时；worker 重新出现时由 coalesced heartbeat history 刷新 session 观测，新旧
assignment id 不匹配的迟到上报仍因不存在匹配 assignment 而被拒绝。

数据库只保留 `workers`、`worker_sessions`、`runs` 和 `events` 等历史模型，不存在 `tasks` 或
`task_leases`。Workers 页面展示 registry/session、当前内存 assignment 和 worker run 历史，
不提供 persisted requeue/cancel。worker 不持有 Linear credential，不调用 tracker。多 worker、
跨 Panel HA、capability pool 和重写执行器不属于当前实现。
