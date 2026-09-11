---
title: Panel / Worker Execution Design
genre: design
domain: [worker, architecture]
status: current
language: zh-CN
updated: 2026-09-11
design_status: landed
---

# Panel / Worker 执行设计

Linear 是“当前是否有工作”的唯一事实源。Panel 是唯一访问 Linear 的组件；worker 仅使用
register、claim、heartbeat 和 task event API。PostgreSQL 保存 worker/session 身份以及 run/event
历史，但不保存待执行工作。

`Worker.AssignmentManager` 是单 worker deployment 的 assignment/lease 所有者。它串行处理
claim，因此同一 Panel 实例同一时刻最多发布一个 assignment。每次 claim 都验证 session 为 online、
heartbeat 未超过 freshness cutoff 且调用方当次 `available_slots > 0`，再实时读取 Linear candidates，按 priority、created_at、identifier 排序，再按 issue id
读取 Linear 并重新验证状态、依赖、routing/profile。Panel 创建新 run 和不可混淆 assignment id，
将 issue 转为 `In Progress`；只有状态更新成功才返回当前 workflow 生成的 payload。
同一成功 claim 同步把 assignment 注入 `Orchestrator` 当前态：`/api/v1/state` 的
`running` 行来自该内存 entry，包含 issue、run、worker、开始时间、session 和 Codex token
进度。该 feed 只是当前态投影，不创建队列或持久 lease；历史事实仍只写入 run/event。

`total_slots` 是 session/deployment 的 advertised aggregate 观测值，不允许并行发放多个 assignment。
有效 admission capacity 仅在存在 fresh online advertised slot、调用方有 slot 且无当前 assignment 时为
1，否则为 0。没有合格 issue、已有 assignment、session 不新鲜或没有 slot 时返回 `{task: null}`，
并附带可测试的 structured admission reason（capacity 0/1 与拒绝原因）。真正访问 tracker 后的连续空
claim 由 `AssignmentManager` 返回强制性的 `poll_after_seconds` 建议：首次为 5 秒，第 2 至 5 次
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
heartbeat 只有在调用 session 持有当前 assignment 且提交匹配 id 时才续期。progress 或 terminal
event 必须匹配当前未过期 assignment；不匹配、过期、Panel 重启前的旧 id 都返回明确冲突。
accepted/progress/completed/failed/cancelled 写入统一 `events` 并更新 `runs`。terminal event 终结
当前 assignment，不产生 queued work。未来执行必须来自新的 Linear fetch、二次校验、新 run 和
新 assignment。
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

Panel 重启不会恢复 assignment 或旧 payload。reconciliation 读取 Linear `In Progress` issue 和
最新 worker run 时间：lease timeout 前保持不派发；超时后将僵尸 issue 转回 `Ready` 并失败终结
旧 run。旧 worker 的迟到上报因不存在匹配 assignment 而被拒绝。

数据库只保留 `workers`、`worker_sessions`、`runs` 和 `events` 等历史模型，不存在 `tasks` 或
`task_leases`。Workers 页面展示 registry/session、当前内存 assignment 和 worker run 历史，
不提供 persisted requeue/cancel。worker 不持有 Linear credential，不调用 tracker。多 worker、
跨 Panel HA、capability pool 和重写执行器不属于当前实现。
