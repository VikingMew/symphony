---
layer: L3
status: implemented
domain: [worker, architecture]
language: zh-CN
---

# Panel / Worker 执行设计

Linear 是“当前是否有工作”的唯一事实源。Panel 是唯一访问 Linear 的组件；worker 仅使用
register、claim、heartbeat 和 task event API。PostgreSQL 保存 worker/session 身份以及 run/event
历史，但不保存待执行工作。

`Worker.AssignmentManager` 是单 worker deployment 的 assignment/lease 所有者。它串行处理
claim，因此同一 Panel 实例同一时刻最多发布一个 assignment。每次 claim 都验证在线 session
和 slot，实时读取 Linear candidates，按 priority、created_at、identifier 排序，再按 issue id
读取 Linear 并重新验证状态、依赖、routing/profile。Panel 创建新 run 和不可混淆 assignment id，
将 issue 转为 `In Progress`；只有状态更新成功才返回当前 workflow 生成的 payload。

没有合格 issue、已有 assignment 或没有 slot 时返回 `{task: null}`。历史 run/event 和旧 payload
从不生成工作。协议继续把 assignment id 放在 `task_id` 与 `lease_id` 字段中以避免 worker 协议
迁移；correlation 同时包含 project、issue、run、worker/session 和 assignment id。

Assignment 只存在于 Panel 内存，包含当前 payload、worker/session、run、issue 和 expiry。
heartbeat 只有在调用 session 持有当前 assignment 且提交匹配 id 时才续期。progress 或 terminal
event 必须匹配当前未过期 assignment；不匹配、过期、Panel 重启前的旧 id 都返回明确冲突。
accepted/progress/completed/failed/cancelled 写入统一 `events` 并更新 `runs`。terminal event 终结
当前 assignment，不产生 queued work。未来执行必须来自新的 Linear fetch、二次校验、新 run 和
新 assignment。

Panel 重启不会恢复 assignment 或旧 payload。reconciliation 读取 Linear `In Progress` issue 和
最新 worker run 时间：lease timeout 前保持不派发；超时后将僵尸 issue 转回 `Ready` 并失败终结
旧 run。旧 worker 的迟到上报因不存在匹配 assignment 而被拒绝。

数据库只保留 `workers`、`worker_sessions`、`runs` 和 `events` 等历史模型，不存在 `tasks` 或
`task_leases`。Workers 页面展示 registry/session、当前内存 assignment 和 worker run 历史，
不提供 persisted requeue/cancel。worker 不持有 Linear credential，不调用 tracker。多 worker、
跨 Panel HA、capability pool 和重写执行器不属于当前实现。
