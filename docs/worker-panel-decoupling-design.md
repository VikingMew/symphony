---
title: Panel / Worker Execution Design
genre: design
domain: [worker, architecture]
status: current
language: zh-CN
updated: 2026-10-09
design_status: landed
---

# Panel / Worker 执行设计

Linear 是“当前是否有工作”的唯一事实源。Panel 是唯一访问 Linear 的组件；worker 仅使用
register、claim、heartbeat 和 task event API。PostgreSQL 保存 worker/session 身份以及 run/event
历史，但不保存待执行工作。

`Worker.AssignmentManager` 是单 worker deployment 的 assignment/lease 所有者。HTTP claim 先同步进入
Orchestrator mailbox，使用当下的 `listening_mode` 准入；manager 不保存第二份 mode。
claim 分为准备与提交两个 supervised task 阶段，始终保留单个 in-flight ownership，其他领取请求
返回 `active_assignment` 空结果，心跳与事件上报继续由 manager 处理。
准备阶段包括候选查询、历史过滤、二次校验和 execution admission，仍使用 5000 ms 总预算；
超时只终止准备 task，返回带具体阶段的 `claim_prepare_timeout`，按 30/60 秒退避。
提交阶段持有固定 run、assignment 和 accepted-event UUID，执行原子 run admission、Linear
started-state 更新和 accepted event 写入。已开始的副作用不受准备阶段总计时器影响；各次 I/O
沿用 adapter 自身 timeout。结果不确定时保留 ownership 并按 30/60 秒重试：先查询同一个 run，
重新读取 Linear 状态确认迁移结果，按固定 event id 去重，不另建 run 或 assignment。
公开 claim call 仍最多等待 6000 ms，超时返回 `worker_claim_pending`，后台继续提交。
因此普通 stop 关闭后续准入，但不撤销此前已准入的提交；force stop 遇到未确认的提交会明确返回
`claim_commit_pending` 失败，不能误报已无工作。发布时才开始租约计时，原 worker/session 的
重复领取返回同一个未过期 assignment，不重复创建 run、写 accepted event 或通知 Orchestrator。
各阶段记录 `worker_claim_stage` 的 phase、stage、elapsed_ms、claim 和 worker/session 标识；
候选查询与 run-history 读取、run admission、Linear transition 的耗时可分别定位。
候选过滤与二次校验各自只读取一次所需的最新 run history，并显式返回数据库读取错误。
规范边界见 [worker claim preparation and commit](spec-orchestration.md#worker-claim-preparation-and-commit)。
`AssignmentManager` 同时拥有
Panel 内存中的 worker/session liveness：每个 entry 以 worker/session 为 key，保存最近一次
`last_seen_at`、worker/session 身份以及 registration 广告的 `total_slots`。该 entry 只有在
`last_seen_at` 落在 `worker_heartbeat_interval_seconds() * 3` 窗口内才 fresh；超过窗口即 stale，
继续保留在内存中也不计容量、不准入 claim。每次 claim 先按进入准入时刻的内存 freshness
snapshot 判定，再记录本次已通过 identity/protocol 的 request 观测供后续请求使用，因此已经过期的
entry 会拒绝当前 claim，但该请求可刷新下一次 claim 的 last-seen。freshness 判据不读取
`worker_sessions.last_heartbeat_at`，也不把由该列派生的 persisted offline/stale 状态作为热路径
准入依据。claim admission 顺序是：Orchestrator listening gate、内存 session freshness、调用方
`available_slots > 0`、environment failure circuit、当前 assignment，然后才实时读取 Linear candidates，
按 priority、created_at、identifier 排序，再按 issue id 读取 Linear 并重新验证状态、依赖、
routing/profile、listening mode 和持久 `blocking_decision`。candidate selection 与 tracker
revalidation 共用同一检查：`transition_status = completed` 时预期实时状态为 `Blocked`，否则预期
`origin_state`；decision 的非空 `run_id` 还必须等于最新持久 run id。缺少任一 scope 返回 typed
`missing_scope` stale，state/run 不匹配也为陈旧。三种 mode 的规则为：

- `not_listening` 在 Linear candidate read、run 创建、issue 迁移和 `task.accepted` 写入前返回空 claim。
- `listening_refine_only` 在排序后的逐候选 admission 中只接受 refinement state；过滤靠前的
  implementation candidate 后继续检查同批次后续候选。
- `listening_all` 保留 refinement 与 implementation 的现有 admission。

Panel 创建新 run 和不可混淆 assignment id，并从 `AgentRunner.Policy` 的唯一
profile-to-started-state 映射推导 worker 起始态：
`refinement` 使用 `Refining`，`implementation` 使用 `In Progress`。非 started issue 必须先按当前
workflow contract 验证并执行 `Todo -> Refining` 或 `Ready -> In Progress`；只有状态更新成功才返回当前
workflow 生成的 payload，返回的 assignment issue、payload issue 和 prompt 当前状态都使用该 started state。
同一成功 claim 同步把 assignment 注入 `Orchestrator` 当前态：`/api/v1/state` 的
`running` 行来自该内存 entry，包含 issue、run、worker、开始时间、session 和 Codex token
进度。该 feed 只是当前态投影，不创建队列或持久 lease；历史事实仍只写入 run/event。

candidate 二次校验和 worker/session 选择完成后，`RunAdmission.resolve/3` 在任何 issue、run、assignment
或 executor 写入前生成一次不可变 decision。它只含 `execution_mode`、`workspace_authority`、`source`
和 `limits`。新 worker run、assignment、payload 与 Orchestrator running entry 消费同一个 decision；
`handle_worker_task_started/2` 只保存 assignment 中的值，不再次读取 mode、source 或 limits。

issue upsert、issue row lock、同 issue running run 检查和新 run 创建位于同一个 PostgreSQL
transaction；running issue run 的 partial unique index 是跨 manager/caller 的最终原子边界。两个独立
claim 同时选中同一 issue 时，最多一个创建 run/assignment，另一方返回
`admission.reason = active_run` 与现有 run id。listening、容量、session freshness、已有 assignment
等本地快速路径的 Linear 调用数为 0；只有进入 candidate admission 的路径读取 Linear。这两类计数
不能用 claim HTTP 请求行数互相代替，既有 5/30/60 秒 claim cadence 与 `poll_after_seconds` 不变。
HTTP worker authority 是 `{:http_worker, worker_id, session_id}`，readiness 只消费已通过的 live context，
不把 worker-local workspace/cache/log path 投影到 Panel state、payload 或历史。所有 source 字段继续
来自同一 composed workflow 的 project slice。

历史去重门只把 worker started states 当作已启动态：`Refining` 和 `In Progress`。候选 issue 处于
这两个状态之一时，最新 worker run 必须是 `succeeded`、`failed` 或 `cancelled` 才能重新 claim；最新
worker run 仍是非终态时不得重复派发。默认 `tracker.active_states` 仍是 `Todo`、`Ready` 和
`In Progress`，不默认派发 `Refining`。

`total_slots` 是 session/deployment 的 advertised aggregate 观测值，由 fresh 内存 liveness entry
汇总为 worker-mode deployment capacity，不允许并行发放多个 assignment。有效 admission capacity
仅在存在 fresh 内存 entry、调用方有 slot 且无当前 assignment 时为 1，否则为 0。没有合格 issue、
已有 assignment、内存 session 缺失/过期或没有 slot 时返回 `{task: null}`，并附带可测试的 structured
admission reason（capacity 0/1 与拒绝原因）。若候选 issue 的 `blocking_decision` state/run scope
仍匹配，claim 返回 `admission.reason = blocking_decision`，并记录包含 issue、worker/session、blocking
reason、origin state、run id 和 decision time 的 `event=worker_claim_skip` 日志。若 decision 陈旧，
同一次 claim 以原 JSON 为 CAS 条件把 decision/streak 写为 `NULL` / `0`，记录带 source、cause 和旧
scope 的 clear event，清除旧 run 的 blocked/retry/failure/stale-claimed 投影，并继续后续 gate。
CAS 发现 replacement 时不清 streak、不释放投影，而是立即重读 replacement；同次 claim 创建的
新 run claimed/running 投影按 run identity 保留。真正访问 tracker 后的连续空 claim 由
`AssignmentManager` 返回强制性的 `poll_after_seconds` 建议：首次为 5 秒，第 2 至 5 次
为 30 秒，第 6 次起为 60 秒并封顶。worker 必须按建议调度下一次 claim；为滚动升级兼容旧
Panel，字段缺失时回退 5 秒。持续空闲时新任务最多额外等待 60 秒。

Orchestrator 的持久 blocker 投影在同一 `blocking_decision` 对象中携带 `reason`、
`origin_state`、`run_id` 和 `decided_at`。共享 presenter 把该对象同时提供给 Dashboard 和
`/api/v1/state`；临时 input block 没有该对象，也不生成 decision 行或清理操作。Dashboard 的认证页面
和认证 control API 共用串行进入 Orchestrator mailbox 的人工清理命令。命令首次清空持久 decision 与
streak 时返回 `cleared`，后续调用返回 `already_cleared`；同时只移除旧 decision/run 对应的
blocked、claimed、retry 和 failure 投影并刷新 Dashboard，较新 run 的投影保持不变。该操作不创建
run、不写 Linear，也不改变 issue snapshot 或 run history；若 Linear 仍为 `Blocked`，仍需运营者另行
恢复到可派发状态后才会进入既有 claim 准入。

`not_listening` 的空响应稳定包含 `reason = not_listening`、`capacity = 0` 和
`listening_mode = not_listening`；refine-only 仅因 mode 过滤为空时使用 `reason = listening_mode`。
两种结果都记录带 worker/session、reason、capacity、listening mode 的
`event=worker_claim_skip`。普通 stop-listening 成功返回时，所有更早进入 mailbox 的 claim 已结束，
后续 claim 均先看到关闭态；已有 assignment 保持不变，只有 force-stop/cancel-current 负责取消。

Orchestrator 的普通 poll 与 active retry 共用 worker-mode deployment capacity 刷新。若
`AssignmentManager.available_worker_slots/0` 的同步调用明确以默认 5000 ms timeout exit 结束，该次
刷新必须 fail closed 为容量 0，不派发且不改变 listening mode；后续刷新仍重新查询内存 fresh
liveness，不复用旧容量。每次 timeout 记录 warning：
`event=orchestrator.capacity_query_timeout execution_mode=worker timeout_ms=5000 fallback_capacity=0`。
其他 exit 不降级，centralized mode 容量语义不变。

worker mode 的 active retry 在刷新容量后释放本次 claim/retry ownership，保留该 issue 的
`failure_counts`，等待下一次 fresh live claim；它不进入 centralized dispatcher，也不启动 Panel-local
或 SSH agent。Panel restart 后的 reclaim 同样只能由新 live claim 产生新 run/assignment，不能用路由
切换重置失败预算。

Orchestrator 构造时持有 worker capacity query callback；默认 callback 仍为
`AssignmentManager.available_worker_slots/0`。该 callback 只提供 process-local constructor dependency
injection，使测试能用显式 `:run_poll_cycle` 和 message-controlled query outcome 逐次验证 timeout 与恢复，
而不暂停全局 manager 或等待 wall-clock timeout。它不是持久化或 operator-configurable runtime policy；
传入无效 callback 时显式失败。这个 start option 只改变 dependency construction：默认 callback、
5000 ms timeout、exact timeout-exit match、fail-closed policy、warning 和 operator-visible behavior 均不变。

`agent.max_retry_backoff_ms` 只限制 Orchestrator 的 failure-retry 排程，不控制 worker claim。
worker claim request 不携带 prospective issue id，也不保存 per-issue retry/cooldown 状态；再次 claim 的
时间只取 Panel 下发的 `poll_after_seconds`，能否认领则由下一次 Panel admission 判定。

Linear 429、5xx 或 request failure 会立即停止 workflow 遍历，不能被后续 workflow 的空结果
覆盖。首次连续错误建议 30 秒，后续错误建议 60 秒并封顶；HTTP 分别映射为 429 和 503，响应
顶层同时包含结构化 `error` 与 `poll_after_seconds`。tracker 再次成功会清除错误 streak，并把
该次空结果作为新的首次空 claim；成功 assignment 清除全部 streak。worker 在 claim client 的
内部重试耗尽后，对 HTTP 429/5xx 同样按 30、60 秒退避，任一成功 claim 清除该 HTTP failure
streak；401 仍执行既有 session recovery。

已有 assignment、没有 slot 或内存 session 缺失/过期的快速路径不读取 Linear，也不改变 tracker
streak。历史 run/event 和旧 payload 从不生成工作。协议继续把 assignment id 放在 `task_id` 与
`lease_id` 字段中以避免 worker 协议迁移；correlation 同时包含 project、issue、run、
worker/session 和 assignment id。

Assignment 只存在于 Panel 内存，包含当前 payload、worker/session、run、issue 和 expiry。
匹配当前 assignment 的 terminal event 若因 `invalid_worker_summary` 被拒，Panel 仍返回 422，且只在该
assignment 内存值上保存最后一次类型化 rejection：validator message、terminal event type，以及
attempted summary 的 `phase`、`outcome`、`reason`、`validation_status` 和 gate index/status/exit code。
该白名单不保存原始 invalid detail；路径和 credential-shaped 值在进入该内存证据前被替换或 redact。
新的 rejection 覆盖旧值，合法 terminal event 继续走既有持久化和 assignment 清理路径。
heartbeat 响应路径不等待 worker/session history 持久化。controller 完成 identity/protocol
解析后，successful registration 同步建立新的内存 liveness entry；heartbeat、claim 和匹配当前
assignment 的 task event 都记录 worker/session last-seen。heartbeat 同时把 worker/session
observation 交给 `Worker.HeartbeatHistory`；该进程按 worker/session 合并后异步调用
`heartbeat_worker/2`，其结果只服务 `/workers` registry/session history，失败只写日志，不改变本次
heartbeat 的 HTTP status、`Retry-After`、`worker_api.heartbeat_failed_attempts` 或任何调度/repair
决策。没有提交 active lease 的 idle heartbeat 不等待 `AssignmentManager` 临界区，直接返回成功和空续期列表。提交 active lease 的 heartbeat 只进入
`AssignmentManager` 的短临界区尝试续期；只有调用 session 持有当前 assignment、提交匹配 id 且 lease
未过期时才续期。claim 与 reconciliation 的出站 Linear I/O 都在 supervised task 中，因此该临界区
只执行内存 lease/cancellation 状态转换。该内存续期临界区未在 heartbeat 预算内完成时，worker-v1 API 返回 retryable 503，
稳定错误码为 `worker_heartbeat_unavailable`，响应包含正数 `retry_after_seconds` 和 `Retry-After`
header，且不包含 crash stack。该失败只计入内存 `worker_api.heartbeat_failed_attempts`，不创建 queued
work、新 assignment、failed run 或自动修复动作。
新的 progress 或 terminal event 必须匹配当前未过期 assignment；不匹配、过期、Panel 重启前的旧 assignment 都返回明确冲突。
accepted/progress/completed/failed/cancelled 写入统一 `events` 并更新 `runs`。terminal event 终结
当前 assignment，不产生 queued work。未来执行必须来自新的 Linear fetch、未清除 blocking decision
检查、二次校验、新 run 和新 assignment。

事件持久化与租约隔离的规范由 [Worker Event Persistence and Lease Isolation](spec-orchestration.md#worker-event-persistence-and-lease-isolation)
拥有。实现由 `Worker.EventWriter` 在 supervised task 中调用 persistence transaction；manager 保存
单个 `event_task` 的 monitor reference 和调用方；终态失败或结果不确定时保留该操作，每秒用同一
event ID 重试确认。收到提交结果后才通知 orchestrator、确认取消或
释放 assignment。续约期间修改的 expiry 留在 manager 当前状态中，不用 task 的旧快照覆盖。
`expire_assignment` 也通过该 writer 收尾；失败后保留 assignment 及本次 expiry event ID，在下次
过期检查重试。worker client 在发起 HTTP 前生成事件 UUID，Runtime 把终态 UUID 与 terminal payload
一起保留；持久层复用 `events` 主键去重，无新队列表或 schema migration。该拆分不改变 worker
Runtime 自身同步执行 HTTP 的方式，也不声称移除了 manager 的所有其他同步依赖。


worker 完成本地执行后保留 assignment 与待确认 terminal payload，直到 Panel 接受相同 task/lease 的
terminal event。Panel 连续返回 503 时沿用固定 `lifecycle_retry_seconds` 间隔；越过原有 max attempts
后不丢弃 pending terminal、不释放 assignment。Panel 恢复后，同一 terminal 只终结原 run，并通过
`RunLifecycle` 写入非空 `finished_at`、`failure_reason` 与 `failure_evidence`。该投递修复不改变 claim
cadence，也不增加指数退避、自动熔断或冷却。
accepted/progress 路径同时更新 `Orchestrator` 当前态：`task.progress` 携带
`codex_session_started` 或 Codex app-server 原始消息时，Panel 更新对应 running entry 的 session、
last event/message 和绝对 token delta；terminal event、取消、expiry 或 reconciliation 失败旧 run 时
移除 running entry，并将 ended runtime 计入聚合。`retrying` 与 `blocked` 仍由 Orchestrator
拥有：worker `failed` 结果在预算内进入 retry，预算耗尽或 `blocked` 结果进入持久 blocker。

源码准备 progress 与 Codex progress 共用 `task.progress` 的持久化入口，但投影路径不同。Executor
只向 Runtime 传 phase 参数 `source_preparation`，其 payload 只含 `source`、`operation`、`status` 和
`detail`；Runtime 用 atom `:phase` 写入一次，避免 atom/string 双键。operation 覆盖 clone、fetch、
branch lookup、targeted deepen、merge-base、merge、checkout 与 DAG verification，每次 operation 先发 `started`，数据 chunk 发 bounded
`output`，最后发 `completed` 或 `failed`。AssignmentManager 先成功持久化匹配 assignment 的 event，
再把 source progress 发送到既有 `system_worker_update` mailbox；SessionHistory 按
source/phase/operation 合并为 `system_progress`。Codex payload 继续进入原有
`worker_task_progress`/Codex reducer，不改变 token 与 session 更新语义。

这些源码操作在 hook/session/Codex 前完成。Runtime 把 timeout 与非 timeout 准备失败都放在顶层
`source_preparation`；reason 分别为 `source_preparation_timeout` 与 `source_preparation_failed`，操作差异
只进入既有 `clone_failed` / `fetch_failed` / `checkout_failed` evidence 闭集。任何失败都不继续到旧
HEAD、本地 branch fallback、hook 或 Codex。

手动 `cancel-current` 是当前内存 assignment 的控制动作，不是持久任务状态。Panel 在当前
assignment 上记录 pending cancellation；只有持有同一 worker/session 且 heartbeat 提交匹配 active
lease 时，heartbeat 响应才返回内存态 `cancel_task` command。发送 cancel command 后不再续期该 lease。
worker 收到 command 后记录可观察日志/`task.progress`，停止 executor 和当前 Codex app-server
session/process，再上报 terminal `task.cancelled`。Panel 只有在该 terminal event 持久化、run 转为
`cancelled` 且通知 Orchestrator `:cancelled` 后，才向控制 API 报告 `cancelled`。没有当前 assignment
或 `project_id` 不匹配时返回 `no_active_assignment`，不请求 worker stop，也不暗示旧 worker 本地进程
状态。持久化/transition、cancel delivery 或 worker 终止无法完成时返回 `failed`。该路径不增加
persisted task queue、persisted cancel record、cancel-by-run/issue 或 requeue 语义。

terminal event 必须携带归一化的 `outcome`（`success` / `blocked` / `failed` / `cancelled`），由 worker 侧的
Codex adapter 判定，Panel 不得再按 reason 分类。Panel 只按该字段分流：`success` 与 `cancelled` 清理
该 issue 的失败链；`blocked` 立即持久化 blocking decision 并投递 Linear 评论与 `Blocked` 状态；
`failed` 消耗一次 `agent.max_failure_retries` 预算，耗尽后同样持久化 blocking decision。outcome
缺失或不在上述取值内按 `failed` 处理，协议异常不得绕过失败预算。
worker executor 对两种无 final handoff 的结构化证据直接产生 `blocked` / `handoff_failed`：一是 payload
issue description 首个非空行精确为 `交付路径:宿主 push` 且 workspace 根存在
`<issue-identifier>.patch`；二是同一 Codex session 的 `create_pull_request` 成功并带 PR URL，且
`linear_task_update` 的 target state 经现有 state-name 规范化后为 `Ready to Merge`。前者保留
root-relative patch path 与 `需宿主 push`，后者保留 PR URL、规范化 target state 及已提供的 branch、
commit。两者均在 validation 后落 `blocked`，gate 失败时仍保留 blocked 与实际 gate 结果。
self-reported blocked、marker-only、patch-only、permission-detail-only 均不满足 host-push 判据；两种
结构化证据都不存在时，missing handoff 仍是 `failed` 并消耗普通预算，bounded detail 指明缺失事件或
PR URL。
failure/no-progress producer 使用 running entry 的实时 `Refining` / `In Progress` state 与 run id；
merge-conflict 只接受带非空 run id 的 completed handoff，并使用第二次 `Ready to Merge` 读取；review
findings 使用 review job run id 和投递时的实时 `Ready to Merge`。有效 decision 存续期内自动 retry
被取消和抑制。人工重跑产生较新 run 表示显式重试，即使 state 未变也使旧 decision 作废。
当 worker 内 Codex 命令执行能力不可用（例如 bwrap/user namespace 创建被拒）时，worker/Codex
adapter 必须快速产出同一 terminal `failed` outcome，并在 summary reason 中保留可区分原因；Panel
仍只按 `outcome` 路由，不把 assignment 留在 `In Progress` 等待 stall/turn timeout。

Panel 的 normal Orchestrator poll 与 worker claim 都读取一次 installation `dispatch_scope` 候选集，
查询状态是 enabled workflows 的 `tracker.active_states` 并集。两条路径共用同一个 context resolver：
有 Linear project 的候选按 `projects.linear_project_slug -> tracker.project_slug` 映射到唯一 enabled
Symphony Project；无 Linear project 的候选只接受显式 internal fallback slug。随后在所选 workflow
上下文内再次校验 active state、routing/profile、capacity 与 history。缺少 fallback、找不到上下文或
候选偏离 team/project scope 时写 typed `admission_rejected`，不创建 run 或 assignment。normal poll
失败只结束当前轮，下一次仍由固定
`polling.interval_ms` 触发，不新增 retry、backoff、circuit 或 cooldown。Linear 400、429、5xx 和
typed transport failure 会写入 project-associated `linear.request_failed`，payload 包含 operation、
status/reason 与 project slug。

Panel 重启不会恢复 assignment、旧 payload 或 worker/session liveness map。每轮 reconciliation 先按
enabled workflow 的 distinct `tracker.project_slug` 去重，再在单个 supervised task 中对每个 slug
各读取一次 Linear `In Progress` issue。整个 task 使用 5000 ms
预算；超时终止本轮，下一轮不与它重叠。结果 cast 携带不可复用的 round reference，manager 只接受
当前 round 一次；迟到或重复结果不改变状态。tracker error 与 timeout 分别记录
`worker_reconcile_tracker_error` 和 `worker_reconcile_tracker_timeout`，与 run 的
`linear.request_failed` event。reconciliation 结合最新 worker run 时间：lease timeout 前保持不派发；
超时且当前态没有 assignment 时只写一次 `run.orphaned` operator signal，不移动 Linear state、不终结
run、不重新派发。判据不调用 session heartbeat 过期扫描，也不以
`worker_sessions.status` 或 `last_heartbeat_at` 作为僵尸回收准入。重启后旧 session row 单独存在时
不提供 deployment capacity 或 claim admission；到 worker 下一次 registration、heartbeat、claim 或
当前 assignment task event 记录内存 last-seen 前，Panel 将该 session 视为未知。未知窗口内不重新派发，
直到 run 级 lease 超时；worker 重新出现时先建立新的内存 liveness，新旧 assignment id 不匹配的迟到上报
仍因不存在匹配 assignment 而被拒绝。未重启但 worker 停止发送请求时，内存 entry 可继续存在，但一旦
超过 `worker_heartbeat_interval_seconds() * 3` freshness window，即不再贡献 capacity 或 admission。

operator 在 Events 和 run history 核对 orphan signal、lease 时间与当前 state 后，先记录说明评论并把
issue 移回 `Todo`。下一次显式 claim 才把该动作视为重跑意图：原子 admission 先用
`assignment_expired` 与 `operator_manual_rerun` evidence 终结旧 run，再创建且只创建一个新 run。

当前 assignment 在持有 `invalid_worker_summary` rejection 时到期，Panel 从该白名单 rejection 构造一个
`assignment_expired` `RunFailure`。同一个值驱动 synthetic `task.failed`、terminal `run.failed`、
`runs.failure_reason/failure_evidence` 和 Orchestrator `worker_task_finished` 通知。没有 terminal rejection
的普通 lease expiry 继续使用 `worker_process_termination`，并保留既有
`{phase: lease, reason: assignment_expired}` evidence。rejection 不持久化为独立队列；Panel 重启后仍按
现有 reconciliation 契约收口，内存 rejection 不恢复。

数据库只保留 `workers`、`worker_sessions`、`runs` 和 `events` 等历史模型，不存在 `tasks` 或
`task_leases`。Workers 页面展示 registry/session、当前内存 assignment 和 worker run 历史，
不提供 persisted requeue/cancel。worker 不持有 Linear credential，不调用 tracker。多 worker、
跨 Panel HA、capability pool 和重写执行器不属于当前实现。
