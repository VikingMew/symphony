---
title: Host-side Execution Probe Design
genre: design
domain: [execution, workers, routing, operations]
status: current
language: zh-CN
updated: 2026-11-01
design_status: proposed
---

# 宿主侧执行探针设计

本文是 SYM-173 的调研交付，描述一个由宿主预先准备执行环境、探针只负责领活、维持租约、
启动 Codex、交活或如实报错的目标设计。本文不声明能力已经落地，也不修改现有 worker 协议、
工作流状态、配置或部署。后续实现必须按本文 roadmap 另开实现票。

## 状态、证据基线与约束

本文的仓库事实统一锚定
`origin/main@9afdf305dfae2ec71ec9fadc698d1e9fab7b12c6`。2026-10-24 执行
`git fetch origin` 与 `git ls-remote origin refs/heads/main` 均得到该 SHA；因此本文没有继续使用评审
评论中曾出现、但当前远端不可复核的 `c212b96`。下文的 `文件:行号` 均指向这个完整 SHA。

现状边界如下：

- Panel 独占 Linear、profile、prompt、dispatch 与单个内存 assignment；外部 worker 独占 checkout、
  hooks、Codex、gates、handoff、证据和清理（`docs/execution-runtime-design.md:13-20`）。
- worker 只调用 register、claim、heartbeat 与 task event API，PostgreSQL 保存身份及 run/event 历史，
  不保存待执行工作（`docs/worker-panel-decoupling-design.md:13-20`）。
- 同 issue 的 running run 由行锁事务和 partial unique index 原子保护
  （`docs/issue-persistence-design.md:44-56`）。
- Compose 服务不得拥有容器引擎 CLI、socket、特权、daemon 或容器管理面
  （`docs/compose.md:35-53`）。
- 长期隔离阶梯已经列出 Local Worker、Host-managed Container Worker 与 SSH Worker，且明确宿主托管
  容器不能解释为 Compose 内 DinD 或 socket passthrough
  （`docs/long_term_direction.zh-CN.md:540-550`、`docs/long_term_direction.zh-CN.md:678-688`）。

本文所有数字只有三种来源：上述基线中的既有契约、由既有配置值计算的公式，或本次设计修订明确
确认的本机默认值。host probe 的已确认默认值是 5 秒 heartbeat、30 秒 lease 和 30 秒本地保守 deadline。

## 已确认决定：单页摘要

| 决定 | 单一推荐 | 主要代价 | 阻塞的第一张实现票 |
| --- | --- | --- | --- |
| 拓扑 | Panel 容器监听 `:4000`，Docker 只向宿主发布 `127.0.0.1:4001`；Docker 外的宿主探针使用 `http://127.0.0.1:4001`。 | 只覆盖同一宿主；不提供 LAN、WAN 或公网入口。 | HP-1 |
| 隔离档位 | 首个切片只落在 `Local Worker` 的宿主进程档；不把 SSH、远端宿主或宿主托管容器混入首个协议。宿主身份、凭据与隔离由 operator 选择，产品不提供 sandbox 或安全认证。 | 探针继承 operator 所选宿主边界中可见的文件、会话和凭据，风险由该边界决定。 | HP-1 |
| 路由策略 | 用唯一 Linear label `execution:host-only` 声明必须宿主执行；缺省继续走当前默认执行面。Panel 先做 project/scope gate，再以需求和已验证 capability 确定性匹配，禁止到达顺序决定执行面。 | 需要 label 治理、snapshot/run 证据扩展和旧 Panel 回滚前的停听/清标操作。 | HP-1、HP-2 |
| 配置权威 | Panel 策略进入 installation singleton；root、bearer token 文件路径、宿主 workspace root、Codex 启动参数属于探针部署拓扑；project context 仍只来自现有 PostgreSQL workflow/project 映射。 | 一个部署要同时管理 Panel 设置与宿主本地配置，但两者不能互相覆盖。 | HP-1 |
| 身份与认证 | 每个安装使用一个静态 bearer token，存于宿主 `0600` 文件；静态 `probe_id` 与每进程 `session_id` 只用于路由和可观测。 | token 与宿主已有身份处于同一 operator-owned 边界；当前不提供 enrollment、CA、证书轮换或撤销生命周期。 | HP-1 |

五项决定共同定义当前 local-only 切片；后续实现票不得把远端传输、每探针身份生命周期或多探针路由
隐式加入 HP-1。

## 1. 探针职责边界

### 1.1 判据、候选、代价与推荐

判据是探针必须能完整执行“领活、heartbeat/lease、启动 Codex、交活/报错”，同时不能成为 source、
credential、toolchain、network 或 GUI 环境的第二权威。现有外部 worker 自己拥有 checkout、hooks、
gates 与 cleanup（`docs/execution-runtime-design.md:13-20`），而本探针的产品目的恰好要求这些准备动作
归宿主，因此这是一个明确的新执行 surface，而不是给现有 container worker 增加开关。

| 候选 | 代价 | 判定 |
| --- | --- | --- |
| A. 探针复用完整 execution-worker pipeline，自行 clone、装依赖、准备凭据和清理 | 实现复用较多，但职责与票面相反；还会在宿主形成第二份 source/config authority。 | 淘汰 |
| B. 宿主预备全部资源，探针只检查声明的 readiness、启动 Codex、续租并上报 | 宿主部署前置工作更多；readiness 失败必须显式返回而不能自愈。 | 推荐 |
| C. Panel 通过 SSH 进入宿主完成准备和启动 | 集中控制方便，但属于 SSH Worker 档；需要入站 SSH、远程 shell 与另一套 credential 边界。 | 留作独立 SSH 路线，不进入首切 |

推荐 B。`WorkspacePreflight` 当前拥有 Panel-local root 的可写/可创建判定，而 HTTP worker 只消费
worker/session readiness，不让 Panel 探测 worker filesystem（`docs/workspace-source-layout-design.md:167-202`）。
host probe 延续后半条边界：宿主拥有 readiness，Panel 只消费有界结果。

### 1.2 谁准备、谁拥有、探针只知道什么

| 资源 | 准备者 | 权威/所有者 | 探针最小知情面 | 失败处理 |
| --- | --- | --- | --- | --- |
| workspace 与源码 | 宿主部署者或宿主自动化 | 宿主；每个 issue 的 cwd 必须位于配置 root 下 | 一个本地 workspace root、assignment 的 issue identifier、最终 cwd 与只读 readiness manifest | 不 clone、不 fetch、不修复；上报 `environment_unavailable` 或既有 source failure evidence |
| Linear/GitHub/Codex 凭据 | 宿主部署者；Panel 独占 Linear backend token | 各凭据原有服务与宿主 secret store | 仅继承启动 Codex 所需的明确 allowlist 或文件路径；永远不知道 Linear API key | 缺失或拒绝时返回 typed evidence，不打印 secret |
| 工具链与依赖 | 宿主部署者 | 宿主 package/runtime 管理 | Codex 可执行文件、固定启动参数及 readiness 结果 | 不下载、不安装、不回退版本；启动失败按既有 runtime failure 映射 |
| 镜像 | 宿主部署者；宿主进程方案无需镜像 | 外部基础设施 | 无镜像或容器引擎知识 | 不调用容器引擎；若部署者外包一层容器，仍在 Compose 外管理 |
| 网络暴露 | Panel 容器监听 `:4000`，Docker 发布宿主 loopback `127.0.0.1:4001` | Panel 部署者与宿主 Docker 拓扑 | 固定 root `http://127.0.0.1:4001` | loopback 不可达时只重试协议动作并最终服从 lease；不开放 LAN/WAN 端口 |
| GUI/浏览器/交互授权 | 登录宿主的真人 | 宿主桌面 session 与相关账号 | 仅当票面逐项要求时，知道 `gui_session`、`interactive_session` 或 `manual_pr_handoff` capability 是否满足；不保存真人密码 | 要求的 capability 不满足时拒绝 claim；未要求这些能力的 host-only 票可由 headless 宿主领取 |

这一定义复用文件系统硬边界：agent cwd 是当前 run 的 per-issue workspace，路径必须留在配置 root 下
（`docs/spec-reliability-security.md:157-169`）；同时扩展 `workspace_authority` 为已验证的
`host_probe` authority。Panel 不接收、显示或持久化宿主绝对路径，符合 HTTP worker 当前不把本地 path
投影到 Panel 的边界（`docs/worker-panel-decoupling-design.md:65-78`）。

### 1.3 最小协议与最小知情面

探针最小契约只有五个动作：访问固定 root、注册/恢复 session、claim、带 active lease 的 heartbeat、
task event（progress 与 terminal）。现有 worker API 已覆盖注册、claim、heartbeat/renewal 和 task event
（`docs/ARCHITECTURE.md:288-307`）；host probe 不新建另一套 terminal API。

assignment 只需给出 issue/run/assignment 标识、渲染后的 profile prompt、受限 task-tool policy、
required gates、执行需求、实现分支和不含宿主绝对路径的 workspace key。探针不接收 project credential、
Panel database connection、Linear token、容器 socket、source preparation 命令或任意宿主清理指令。

## 2. 连接与配置模型

### 2.1 拓扑决策

判据是 Panel 与探针位于同一宿主、Panel 仍是 dispatch authority，并且不能绕开 Compose 控制面边界。

| 候选 | 代价 | 推荐理由或淘汰理由 |
| --- | --- | --- |
| A. Docker 把 Panel 容器 `:4000` 发布到宿主 `127.0.0.1:4001`，宿主探针访问固定 HTTP root | 只覆盖同一 Docker 宿主；无需额外网络身份生命周期。 | 推荐；连接只走 loopback，探针不开放端口。 |
| B. Panel 回连每个探针的 HTTP endpoint | 每台宿主需要入站端口、服务发现与防火墙规则；扩大异地暴露面。 | 淘汰。 |
| C. LAN、VPN/overlay 或公网连接 | 需要新的网络暴露、传输认证和运维边界。 | 不在当前 local-only 范围或 roadmap。 |

root 只是本机协议入口，不携带 project context。当前传输是 loopback 上的 plain HTTP，不使用 TLS 或
mTLS。公网边缘仍属于外部基础设施且不在本设计当前范围；现有 Compose 文档禁止服务获得容器控制权
（`docs/compose.md:35-65`）。

### 2.2 配置分层

现有配置权威把 `dispatch_scope`、workspace、agent、codex、worker 与 profiles 放在 installation singleton，
把 Linear project 到 Symphony Project 的 durable mapping 留在 project row
（`docs/workflow-config-authority-design.md:20-40`）。host probe 必须在该模型内扩展。

| 配置 | 候选 | 推荐归属 | 代价/理由 |
| --- | --- | --- | --- |
| Panel root | instance setting / 探针部署拓扑 | 探针部署拓扑 | root 是如何连到本安装，不是业务 routing authority。 |
| 探针身份与认证来源 | 每安装静态 bearer token | Panel 安装 + 宿主 `0600` secret 文件 | 单机部署只需一个 token；当前不增加 enrollment、CA、证书或撤销状态。 |
| heartbeat、lease 与本地 deadline | 探针自定 / Panel 下发 | Panel instance singleton 固定 5 秒 heartbeat、30 秒 lease；探针使用 30 秒保守 deadline | 单一调度时钟和阈值；探针不能放宽 lease。 |
| workspace root | Panel project setting / 宿主本地配置 | 探针部署拓扑 | Panel 不认识宿主 path；宿主必须证明 cwd 在本地 root 下。 |
| Codex 启动参数 | assignment 任意命令 / 宿主 allowlisted launcher | 宿主本地配置，assignment 只选既有 profile | 降低灵活性，但不允许票面注入任意 launcher。 |
| capability | project context / 注册声明 | 探针声明，Panel 校验为闭集并绑定 session | capability 只描述执行能力，不能选择项目。 |
| host-only label 解释 | 每项目配置 / installation policy | Panel instance singleton | 全安装保持一种语义；不复制 project context。 |

推荐是 split authority：Panel 拥有调度与协议策略，宿主拥有只在该机器有意义的连接、path、launcher 和
secret material。`RunAdmission` 继续只消费一份 composed workflow；HTTP worker/local path 不得反填
Panel workflow、decision 或历史（`docs/workflow-config-authority-design.md:62-72`）。项目映射、两级监听
范围和 fallback 继续只有现有 authority（`docs/workflow-config-authority-design.md:30-34`）。

宿主身份、凭据和隔离是 operator-owned boundary，也是本产品的 non-goal。operator 可以选择日常账号、
专用账号、专用机或 VM，并负责记录选择与运行证据；探针和 Panel 都不提供 sandbox，不认证该选择是否
“安全”，也不把其中任一形态作为 HP-1 或 HP-5 的资格前提。

## 3. 与现有控制面契约的复用分析

本项的判据是避免第二套调度/失败协议，同时不能假装 execution requirement、probe identity 和 capability
已经存在。

| 总体候选 | 代价 | 判定 |
| --- | --- | --- |
| A. 原样复用 worker-v1，不增加任何 admission 字段 | 实现最少，但无法阻止 container 领取 host-only 票，也无法证明宿主 capability。 | 淘汰。 |
| B. 新建完整 host-probe queue、lease、event 与 failure API | 能完全独立演进，但复制调度状态、幂等、对账和错误词汇，冲突面最大。 | 淘汰。 |
| C. 选择性扩展 registration/claim/heartbeat，原样复用 terminal、run 与 task tools | 需要协议和 evidence 变更，但每个事实仍只有一个 owner。 | 推荐。 |

### 3.1 三条热路径判定

| 契约 | 判定 | 原样复用部分 | 必须扩展部分 |
| --- | --- | --- | --- |
| claim | **需扩展** | 单个 in-flight reservation、准备/提交、稳定 run/assignment/event identity、原子 single-running-run 与重复 owner 恢复（`docs/worker-panel-decoupling-design.md:17-34`、`docs/worker-panel-decoupling-design.md:70-75`） | candidate 增加 `execution_requirement`，session 增加 `execution_surface/capabilities`，Panel 在副作用前做确定性匹配并选定 probe。 |
| heartbeat/lease | **需扩展** | 只有当前 session、当前 assignment、匹配且未过期 lease 才续约；历史持久化不阻塞 response（`docs/worker-panel-decoupling-design.md:156-169`） | 每次 heartbeat 验证静态 `probe_id`、当前 `session_id` 与 capability 摘要；固定 5 秒 heartbeat、30 秒 lease，探针使用 30 秒本地保守 deadline。 |
| terminal 回报 | **原样复用** | terminal event 的 UUID 幂等、提交后才 ack、失败/不确定时保留 assignment 并重试；分类只由 `RunFailure`/`RunLifecycle` 完成（`docs/spec-orchestration.md:297-327`、`docs/run-failure-classification-design.md:50-62`） | 无新的 terminal vocabulary。`execution_surface` 在 claim/admission 时落证据，不从 terminal payload 反推。 |

没有一条需要新建平行 API。扩展必须落回
`docs/worker-panel-decoupling-design.md`（注册、claim、heartbeat、session/capability）、
`docs/execution-runtime-design.md`（host probe pipeline 与 credential boundary）和
`docs/spec-orchestration.md`（规范 admission/lease/event 语义）。

### 3.2 失败、持久化、可观测与 task tools

- 闭集终态分类保持 `environment_unavailable`、`source_preparation_timeout`、
  `external_dependency_timeout`、`budget_exhausted`、`contract_violation`、
  `worker_process_termination`、`assignment_expired`、`validation_failed`、`runtime_failure`、
  Codex 两类、`cancelled` 与 `operator_stopped`；运行时不能写 `unknown`
  （`docs/run-failure-classification-design.md:26-48`）。
- 请求/协议错误继续使用 `code/retryable/message` envelope；它不是 run 终态的第二词汇
  （`docs/observability-errors-design.md:33-41`）。相关记录使用 `issue_id`，并在适用时带
  `run_id/session_id/thread_id/turn_id/tool_call_id`（`docs/observability-errors-design.md:43-53`）。
- issue snapshot 继续保存 dispatch context，run 的 `project_id` 保存执行 context，accepted event 复制
  同一份证据；Issue Detail 与 Run Detail 分别展示（`docs/issue-persistence-design.md:25-31`）。本设计只
  扩展该 evidence，不建 probe 自有 issue store。
- Codex 仍只能用 task-scoped `linear_task_read`、`linear_task_update`、`create_pull_request` 与
  `handoff`；Linear token 不进入 Codex（`docs/codex-linear-interaction-design.md:40-63`）。手动创建 PR 后，
  `create_pull_request` 的 lookup-before-create 可以确认并复用同一 open PR；最终 writeback 仍在 gates 后
  （`docs/codex-linear-interaction-design.md:139-155`）。

长期方向的 `manual` / `external_worker` 目前只是扩展契约
（`docs/long_term_direction.zh-CN.md:58-61`）。本设计选择扩展 `external_worker` 的执行 surface；
`manual` 只描述真人 gate，不成为另一个 dispatch mode。现有“宿主 push”只在精确 directive 和 patch
同时存在时形成 blocked handoff（`docs/execution-runtime-design.md:273-278`）；它不能代替 host probe，
因为它既不启动宿主 Codex，也不维持 lease。

### 3.3 “探针只负责报错”的写实映射

| 探针观察 | 协议层结果 | 已有 run 分类/面板证据 |
| --- | --- | --- |
| root 不可达、bearer token 错误或 session 注册失败，尚未创建 run | typed request error；registration/claim 拒绝 | 无 run；Workers/Probe registry 显示 `last_error.code` |
| host workspace 缺失、越界或不可写 | terminal failed，bounded readiness evidence | `environment_unavailable` |
| 声明的 executable/toolchain 缺失 | terminal failed，phase 指向 launch/readiness | `environment_unavailable`；已 spawn 后的通用失败才用 `runtime_failure` |
| Codex initialize/thread start 失败 | terminal failed，保留 stage 与有界 summary | `runtime_failure`；现有 startup 映射见 `docs/run-failure-classification-design.md:20-24` |
| Codex turn 失败 | terminal failed | `codex_upstream_capacity` 或 `codex_turn_failed` |
| required gate 非零或超时 | terminal failed，保留 gate evidence | `validation_failed` |
| lease 丢失、进程退出、宿主重启 | 不能再续约；Panel expiry/reconciliation 收尾 | `worker_process_termination`；若先有被拒 terminal，则 `assignment_expired`，见 `docs/run-failure-classification-design.md:93-99` |
| handoff 缺证据或 shape 非法 | terminal failed | `contract_violation` 或既有显式 `handoff_failed` 映射；不创造 probe 分类 |
| 真人拒绝/取消本次交互 | terminal cancelled | `cancelled` |

探针不得把任一失败改写为成功、自动换 workspace、安装依赖、切执行面或放宽 capability。终态由 Panel
验证 summary 后只分类一次，同一值供应 run、event、retry 和 blocker
（`docs/run-failure-classification-design.md:59-62`）。

## 4. 隔离等级对位

判据是首个形态必须直接使用真实宿主 workspace、GUI/browser 与交互授权，同时不让 Compose 服务控制
宿主 container engine。

| 候选 | 适配性 | 代价 | 结论 |
| --- | --- | --- | --- |
| Local Worker / 宿主进程 | 能进入已登录用户 session，直接消费宿主准备的 workspace、toolchain 和 GUI。 | 与宿主用户共享权限，隔离最弱。 | **首个切片唯一档位** |
| Host-managed Container Worker | 由宿主外部基础设施启动，隔离较强。 | GUI、浏览器、interactive auth 和宿主 workspace 透传复杂；容易与既有 execution-worker 混淆。 | 后续可兼容部署包装，不改变 host-probe 协议 |
| SSH Worker | 远程隔离与运维边界清楚。 | 需要入站 SSH、remote shell 与 SSH credential；不自然覆盖本机 GUI。 | 独立路线，不属于首切 |

单一结论是 operator 管理的宿主进程，对应长期阶梯的 Local Worker
（`docs/long_term_direction.zh-CN.md:544-550`）。它只通过宿主 loopback HTTP 连接 Panel，不访问 Compose service
内的 container engine。即使维护者以后把同一探针放入宿主托管容器，启动与引擎操作也只能发生在
Compose 外部；Compose 服务仍满足无 CLI、无 socket、无 daemon、无 privileged 的硬边界
（`docs/compose.md:37-47`）。

## 5. 用途与不适用面

### 5.1 候选覆盖方式

判据是明确 Codex 与真人各做哪一步，不能把“可交互”误写为自动授权。

| 用例候选 | Codex/探针动作 | 真人动作 | 代价与推荐 |
| --- | --- | --- | --- |
| 手动 PR | 票面显式要求 `manual_pr_handoff`；探针启动 Codex；Codex 准备变更、验证、commit/push，或等待外部 PR；随后通过受限工具 lookup open PR 并提交 handoff。 | 在 GitHub UI/企业授权页完成必须的交互、确认或 PR 创建。 | 推荐支持。真人动作是 gate；PR 仍由现有精确 repo/base/head 证据收口。 |
| GUI 调试 | 票面显式要求 `gui_session`，需要同步真人时再要求 `interactive_session`；Codex 启动/驱动应用、收集日志并提出操作；探针续租并转发 progress。 | 在已登录桌面执行视觉确认、授权、复现或输入，并把结果交回 Codex。 | 推荐支持。HP-5 验收真实证明人机交互，但不把 GUI 能力绑定到所有 host-only 票，也不开发 GUI 应用。 |
| 把任意普通自动化票都发给宿主 | 与 container worker 重复。 | 无必要人工动作。 | 淘汰；未标注票继续走默认 surface。 |

### 5.2 不应走探针的场景

- 无需宿主资源、可以在 container worker 中完全自动验证的普通票。
- 来源或操作者不在 operator 已选择并接受的宿主身份、workspace、credential 与网络边界内的票；产品
  不会把不受信任输入自动变成可安全宿主执行的输入。
- 要求探针自行安装 toolchain、clone source、修复 workspace、创建镜像或操作 container engine 的票。
- 需要无人值守稳定重试，但依赖 GUI、浏览器 MFA 或真人审批且无人值守窗口没有操作者的票。
- 只需要 SSH 隔离或远程 shell、并不需要真实桌面 session 的票；应进入 SSH Worker 设计。
- 需要并行多 assignment 或跨 Panel HA 的票；当前 assignment owner 明确是单 deployment、单内存
  assignment（`docs/worker-panel-decoupling-design.md:17-20`、`:85-88`）。

在“不支持”与“让探针代做宿主准备”之间，候选是 fail closed 或 best-effort repair。推荐 fail closed：
前者符合显式失败和最小知情面；后者会引入隐藏状态、权限与不可复核副作用。

## 6. 推荐路线与可拆票实现规划

### 6.1 四轴独立决策

| 轴 | 候选 | 代价 | 单一推荐与淘汰理由 |
| --- | --- | --- | --- |
| 拓扑 | 宿主 loopback；Panel 回连；LAN/WAN | loopback 限于同一宿主；回连要求探针入站暴露；LAN/WAN 需要新的传输与认证边界。 | 宿主 loopback。Docker 把 Panel `:4000` 发布到 `127.0.0.1:4001`，探针固定访问 `http://127.0.0.1:4001`；其余候选不在当前范围。 |
| 隔离档位 | 宿主进程；宿主托管容器；SSH | 宿主进程继承 operator 所选边界；容器 GUI 成本高；SSH 需要另一套入口。 | 宿主进程。它能直接使用宿主准备的环境，并在票面要求时覆盖 GUI/interactive 用途；另外两档保留独立评审。 |
| 路由策略 | label + capability；仅 project scope；先到先得 | label 需治理；project scope 无法表达 surface；先到先得不可预测。 | `execution:host-only` + capability。后两者不能保证 host-only 不被 container 领取。 |
| 配置权威 | 全放 Panel；全放探针；按策略/拓扑拆分 | 全 Panel 泄漏本地路径；全探针形成 dispatch authority；拆分增加部署文档。 | split authority。Panel 拥有策略，宿主拥有机器事实，现有 project mapping 不变。 |

拓扑与隔离遵守现有外部 runtime 分工和 Compose boundary
（`docs/execution-runtime-design.md:11-27`、`docs/compose.md:35-53`）；路由保留 claim 的二次校验和
single-running-run（`docs/worker-panel-decoupling-design.md:43-75`、
`docs/issue-persistence-design.md:44-56`）；配置权威保持现有 singleton/project 边界
（`docs/workflow-config-authority-design.md:20-40`）。

兼容组合：

- 宿主 loopback HTTP + 宿主进程 + label/capability routing + split authority 是最小可用组合。
- 同一协议以后可以被宿主托管容器包装，只要启动者在 Compose 外，仍由 host operator 准备资源。
- `execution_surface=ssh` 可共享 run evidence 字段，但 SSH admission 与 credential 仍由独立 owner 设计。

不兼容组合：

- 把 root 改为 LAN、VPN 或公网地址与当前 local-only 合同不兼容；若未来需要，必须另立设计范围。
- 只按 project scope 路由 + host-only 要求不兼容，因为同项目可同时存在两种票。
- 先到先得 + 双执行面不兼容，因为 container 可能抢走 host-only 票。
- 宿主进程 + 把 `danger-full-access` 当隔离层不兼容；安全边界是 operator 明示选择的宿主身份、凭据和
  隔离方式，产品不增加 sandbox 或安全认证 gate。
- 旧 Panel + 保留活动 `execution:host-only` label 不兼容；旧 Panel 不认识硬 gate，回滚必须先停听并清理活动标记。

### 6.2 session 与 capability 合同

首个 local-only 切片不设计版本协商或多代兼容层。固定 root 接受静态 `probe_id`（例如
`local-host`）和每进程新建的 `session_id`；两者只用于路由、租约归属和可观测，不构成安全边界。
请求认证只使用 6.3 的每安装静态 bearer token。

`execution:host-only` 只选择宿主执行面，不自动加入用途能力。可选能力保持三个独立 label：
`capability:interactive-session`、`capability:gui-session`、`capability:manual-pr-handoff`；缺省得到空的
`required_capabilities`。registration 将探针声明的可选能力冻结到 session，claim 在产生副作用前要求
`required_capabilities` 是 session capability 的子集，heartbeat 只接受当前 `probe_id`、`session_id`
和冻结的 capability 摘要。未知 capability、身份不匹配或需求不满足均返回 typed request/admission
evidence，不创建替代 run，也不放宽 lease。

上线顺序是 Panel schema/可见性先上线但 host routing 关闭，随后配置 token、注册单个探针并通过
readiness，再由维护者启用 label 解释，最后允许 host-only claim。回滚反向执行：先停止 host claim，
等待或显式取消当前 assignment，移除所有 active host-only 标记，再回滚探针和 Panel。

归属判定：注册/session/capability 属于 `worker-panel-decoupling-design` 的**需扩展**合同；host launcher
与 bearer-token boundary 属于 `execution-runtime-design` 的**需扩展**合同；claim/heartbeat 的拒绝时机
属于 `spec-orchestration` 的**需扩展**规范。终态 event 协议原样复用。

### 6.3 探针身份生命周期

HP-1 每个安装只配置一个静态 bearer token。Panel 生成或保存该值；operator 把它写入宿主 `0600`
文件；探针从该文件读取并在 registration、claim、heartbeat 和 task event 请求中发送。token 不进入日志、
run evidence 或 task payload。当前设计没有 enrollment token、CA、客户端证书、按探针轮换、撤销列表或
换机生命周期；token 更换是安装级运维动作，必须在没有 active assignment 时同时更新 Panel 与文件。

稳定 `probe_id`（首个部署可使用 `local-host`）归属于安装，不归属于 project。每次进程启动创建新的
`session_id`，旧 session 不再续租；assignment/event 继续使用既有 UUID 幂等。`probe_id` 和
`session_id` 只提供路由、lease fencing 与可观测关联，认证事实只有 bearer token。项目资格仍由 Panel
的 dispatch scope 和 project mapping 每次 claim 计算。

凭据不得进入日志，且只能验证存在而不能打印（`docs/spec-reliability-security.md:171-175`）。静态 token、
Codex/GitHub 凭据和 workspace 都处于 operator 现有宿主身份、文件权限和网络边界内；产品不要求专用
账号、专用机或 VM，也不把该边界认证为 sandbox。

### 6.4 故障注入与对账矩阵

所有预期终态均从既有闭集选择；event correlation 使用现有 issue/run/session/tool identifiers。推荐组合
必须逐行通过，任一实现若产生第二个 running run、平行失败类或静默 Todo 滞留即失败。

崩溃后的收口有两个候选：A 由产品承诺处置宿主残留进程，代价是把宿主进程卫生扩进探针契约，淘汰；
B 仅由控制面以 lease 到期、run 单次终结、旧 assignment event fencing、single-running-run 和面板末态
收口，推荐。探针正常退出时可以尝试 best-effort cleanup；崩溃或宿主异常后的残留进程由 operator
runbook 处置，不属于产品保证或产品验收。现有执行 runtime 仍以一个 supervised owner 持有完整 assignment
pipeline（`docs/execution-runtime-design.md:152-155`），本设计不扩展该事实为宿主安全或进程清理保证。

| 故障 | 注入点 | 预期 lease/run/event/面板结果 | 对账责任 | 实现票 | 验收类型 | 推荐方案判定 |
| --- | --- | --- | --- | --- | --- | --- |
| loopback 中断 | active run 期间切断 probe→Panel | heartbeat 不达；Panel 时钟令 lease 到期，run 一次性 `worker_process_termination`，旧 assignment event 被 fencing，面板先 stale 后等待合格探针 | AssignmentManager expiry + reconciliation 收口；operator 按宿主 runbook 处理可能残留的进程 | HP-1 | 自动 transport/lease/event 注入 | 通过 |
| 时钟偏移 | probe 时钟快/慢，Panel 正常 | lease 只看 Panel 时间；client timestamp 仅证据，不提前续租/过期；面板显示 server-observed age | Panel lease owner | HP-1 | 自动虚拟时钟 | 通过 |
| 重复 claim | 同一探针重复 claim；若以后启用多探针则两探针同时 claim | DB 最多一条 running run，另一请求有 typed routing/active-run reason，无重复 accepted event；多探针时还需 designated probe | Orchestrator + atomic run admission | HP-1；多探针分支才需要 HP-4 | 并发测试 | 通过 |
| 探针中途崩溃 | Codex 启动后 kill probe | Panel lease 到期，run 只终结一次，旧 assignment event 被 fencing，不产生重复 running run，面板保留 run/session/probe id 与最后状态 | AssignmentManager expiry 收口 run；Panel reconciliation 对账；operator 按宿主 runbook 处理可能残留的进程 | HP-1 | 自动故障注入：断言 lease 到期、单次终态、旧 event 被拒、无重复 running run、面板末态可见 | 通过 |
| 租约过期 | 暂停 heartbeat 超过 lease 后再恢复 | Panel expiry 决定唯一终态；恢复的 heartbeat/event 被拒；新 claim 必须重新读 Linear、建新 run；面板保留最后状态 | AssignmentManager + Panel reconciliation；operator 按宿主 runbook 处理可能残留的进程 | HP-1 | 虚拟时钟/协议/fencing 测试 | 通过 |
| Codex 启动失败 | launcher 返回失败或 handshake 超时 | 当前 lease terminal failed；run `runtime_failure`，event evidence 有 stage，gates `not_run`；面板显示 typed failure | probe adapter + RunFailure | HP-1 | 离线 fake app-server | 通过 |
| 交付回执丢失 | Panel 已 commit terminal，ack 响应丢失 | probe 保留同 event id 重送；Panel 返回原 ack，只存在一个 terminal event/run transition；面板不重复通知 | EventWriter/idempotent receipt | HP-1 | transport fault test | 通过 |
| 孤儿 run | Panel 重启丢失 assignment 或宿主残留 running row | reconciliation 只写 `run.orphaned` 并显示；operator 明确把 issue 置回可重跑状态后，admission 将旧 run 终结为 `assignment_expired` 再创建一个 run | Panel reconciliation + operator | HP-1 | persistence/restart test + 人工 gate | 通过 |

事件 UUID 去重和 uncertain commit 规则来自 `docs/spec-orchestration.md:305-327`；孤儿 run 只观察、由显式
operator rerun 触发替换来自 `docs/run-failure-classification-design.md:101-105`；原子 running 边界来自
`docs/issue-persistence-design.md:44-56`。

### 6.5 路由运行时状态机

统一面板字段：`execution_requirement`、`routing_status`、`routing_reason`、`eligible_probe_count`、
`selected_probe_id`、`routing_since_at`、`execution_surface`。HP-1 固定使用 5 秒 heartbeat、30 秒 lease
与 30 秒本地保守 deadline；等待告警阈值为
`routing_wait_seconds >= max(3 × 5 seconds, 30 seconds)`，即 30 秒。三倍 heartbeat 是既有 session
freshness 窗口（`docs/worker-panel-decoupling-design.md:36-43`）。

| 状态/事件 | claim 判定与转换 | 面板字段 | 运维动作 |
| --- | --- | --- | --- |
| 未标注旧票 | 只允许默认 surface；host probe 不领。加 label 后进入 host routing。 | requirement=`default`，status=`eligible_default` | 无；升级/回滚语义不变。 |
| host-only，无在线探针 | 不 claim；fresh eligible 变为 1 后进入 ready。 | status=`waiting_for_probe`，reason=`no_online_eligible_probe`，count=0 | 30 秒后告警；启动/恢复本机探针。 |
| host-only，能力不匹配 | 不 claim；capability/session 修正后重算。 | status=`waiting_for_probe`，reason=`capability_mismatch`，count=0，并列缺项 | 修正宿主能力或移除错误 label；不改项目映射。 |
| host-only，唯一合格探针 | 该 probe 可 claim；成功后 running。 | status=`ready_host_probe`，count=1，selected=probe id | 无。 |
| host-only，多个合格探针 | 当前 local-only 单探针范围不进入该状态；只有未来明确引入多个探针并启动 HP-4 后才定义 selection。 | 当前范围不产生 `count>1` | 停止额外探针；不得临时发明到达顺序路由。 |
| active host run 中 probe stale | 在 lease 过期前不另 claim；expiry 后按失败/重试预算重新进入等待或 ready。 | status=`running_host_probe` 后转 failure/waiting | 恢复网络；不得手工创建第二 run。 |
| Panel 回滚 | 必须已 stop host claim、终结 assignment、清除 active host-only label；否则禁止回滚。 | status=`rollback_blocked` 只在新 Panel 运维检查显示 | 按回滚清单消除 blockers；不让旧 Panel误领。 |

`routing_status` 是面板投影，不是 Linear workflow state，也不写回 Todo。状态转换始终先通过既有
installation/project scope，再通过 execution requirement，最后才做 capability 与单探针 session 匹配。
任何一层失败都是硬约束；多探针 selection 只有 HP-4 被明确启动后才加入。

### 6.6 迁移与回滚

| 场景 | 迁移结论 | 回滚结论 |
| --- | --- | --- |
| 未标注票 | `execution_requirement=default`，继续走当前 execution mode；不批量加 label。 | 语义完全不变。 |
| 升级时已有 host-only label | 新 Panel 在启用 routing 前先提供只读诊断，确认 label、probe 与 workspace readiness。 | 旧 Panel 不懂 gate；回滚前必须 stop listening、终结 host assignment，并移除/冻结所有 active host-only label。 |
| 合格探针离线 | issue 保持原工作流状态但显示 `waiting_for_probe`，阈值后告警；不转给 container。 | 恢复 probe 或由授权人移除 label；不得自动降级。 |
| 探针更新 | 在无 assignment 时停止旧进程并以新 `session_id` 启动；静态 `probe_id` 和 token 文件不变。 | 先停止 host claim，再恢复原探针进程；不引入协议兼容窗口。 |
| execution evidence | 新 run 写 `execution_surface`；历史 run 保持没有该新证据，UI 显示“未记录”，不猜测。 | 停止写新值后旧 UI 忽略额外 event field；若引入 run column，使用单调迁移，不执行 destructive down。 |

旧历史不伪造 surface。未标注票保留既有默认语义；当前没有协议版本兼容层。

### 6.7 分阶段、可拆票 roadmap

#### 阶段 A：最小可用纵切

**HP-1（需新票，最小可用切片）— 单探针 host-only 端到端。**

- 目标：Docker 把 Panel 容器 `:4000` 发布到宿主 `127.0.0.1:4001`，Docker 外的探针用静态 token
  认证并从 `http://127.0.0.1:4001` 领取一张 host-only 票，验证宿主准备的 workspace，
  启动 Codex，维持 heartbeat/lease，成功 handoff 或按既有词汇失败，最后释放 assignment 或由 lease 回收。
- 进入判据：本设计批准；使用已确认的 `execution:host-only` 和三个可选 capability labels、5 秒 heartbeat、
  30 秒 lease、30 秒本地保守 deadline；测试 fixture 可提供已准备 workspace 和 fake Codex。
- 依赖票：SYM-173；其余均为本票内纵切，不能先拆配置/claim/Codex 横层。
- 退出判据：一条 offline integration test 从 root discovery 走到 success；同一路径注入 Codex 启动失败、
  probe crash、lease expiry 和 terminal ack loss；Panel 证明一个 run/accepted/terminal、正确 correlation、
  task tools 受限、workspace 越界 fail closed、assignment 释放/回收；probe crash 后 lease 到期、run 只终结
  一次、旧 assignment event 被 fencing、没有重复 running run，且面板可见最后状态。
- 自动可复核：loopback protocol、原子 claim、虚拟 heartbeat/lease、fake app-server、event id retry、
  crash/expiry fencing、`RunFailure` exact classification、UI/state serialization、静态无 container-engine/socket
  检查。
- 必须人工 gate：静态 bearer token 写入宿主 `0600` 文件，以及 operator 明示其选择的宿主身份、凭据与
  隔离边界并提供一次
  真实宿主运行证据；不要求 GUI、专用账号、专用机或 VM。责任人是维护者，证据附实现票，阻塞启用
  host routing。
- 运行时副作用：只在测试数据库、loopback Panel 和临时 workspace；不部署、不改真实 label。
- 迁移/回滚：schema 只做前向迁移；feature 默认关闭；停听、终结 lease、关闭 feature 即回滚。

#### 阶段 B：证据与条件性竞争收敛

**HP-2（需新票）— 持久化执行面与离线可见性。**

- 目标：把 issue requirement 和 run `execution_surface` 接入现有 snapshot/accepted evidence，并在 Issue、Run、
  Dashboard 显示等待原因与阈值告警。
- 进入判据：HP-1 纵切稳定，字段名和值域获批。
- 依赖票：HP-1。
- 退出判据：unmarked/host-only 四格路由证据可查询；历史缺值显示未记录；无合格 probe 不静默。
- 故障场景：probe offline、capability mismatch、旧票未标注。
- 自动可复核：migration、serialization/query、UI state、告警公式和无新 workflow state 的静态检查。
- 必须人工 gate：告警接收人与展示文案；责任人是维护者，证据为运维评审，阻塞生产告警启用。
- 运行时副作用：测试 DB 写 snapshot/run/event；无外部调用。
- 迁移/回滚：前向字段迁移；回滚 UI/feature 不改写历史 evidence。

**HP-3 — 不在当前范围。**

每探针 enrollment、mTLS 身份、CA、证书轮换、撤销和协议兼容窗口不属于 local-only 功能或当前
roadmap。HP-1 的静态 per-install bearer token 与 `probe_id`/`session_id` 合同不依赖 HP-3。

**HP-4（条件性新票）— 多探针确定性路由。**

- 目标：只有产品以后明确引入同一安装的多个探针时，才实现 rendezvous selection 和多探针竞争证据。
- 进入判据：存在已批准的多探针需求；HP-2 evidence 可用；当前单探针部署不创建本票。
- 依赖票：HP-2。
- 退出判据：多个合格 probe 的到达顺序不改变 winner；八行矩阵全部满足一个 running run、一个 terminal
  truth 和闭集 failure；restart 后无隐式 requeue。
- 故障场景：本文矩阵全部八类。
- 自动可复核：并发/property test、transport fault、restart/persistence、virtual time 和 exact panel projection。
- 必须人工 gate：竞争容量与告警处置演练；维护者负责，证据附演练记录，阻塞多探针 enablement。
- 运行时副作用：仅本地多进程和测试 DB；无外网、无部署。
- 迁移/回滚：关闭 multi-probe admission 后退回单探针；不更改 issue requirement。

#### 阶段 C：真实本机用例

**HP-5（需新票）— 手动 PR 与 GUI 调试验收。**

- 目标：用真实宿主 session 分别完成一次手动 PR lookup/handoff 和一次 GUI debug，人机责任与 evidence
  进入运维指南。
- 进入判据：HP-1 和 HP-2 完成；若部署明确启用多个探针则还需 HP-4。operator 明示已选择的宿主身份、
  凭据与隔离边界并提供相应运行证据。
  产品不要求日常账号、专用账号、专用机或 VM 中的特定一种。
- 依赖票：HP-2；多探针部署条件性依赖 HP-4。
- 退出判据：真人交互不泄漏 credential，Codex 仍只用 task-scoped tools；中途取消、无人响应和 PR receipt
  丢失均有既有终态/恢复路径。
- 故障场景：真人拒绝、interactive session 消失、PR 已存在、handoff evidence 缺失。
- 自动可复核：PR lookup fixture、tool-policy/redaction、cancel/timeout contract；GUI 本身不自动化。
- 必须人工 gate：真实 UI walkthrough 与 PR 审计，由维护者在 operator 已记录的宿主边界内执行并保存
  evidence，阻塞用途对外宣告；该 gate 不评判或强制账号/机器隔离形态。
- 运行时副作用：只使用 operator 明示批准的测试 repo、身份和宿主边界；产品不强制专用账号或机器。
- 迁移/回滚：关闭 host-only routing；不自动删除人工创建的 PR。

**HP-6 — 不在当前范围。**

异地网络、LAN/WAN、公网 TLS、DNS、远端灰度与对应回滚演练不属于 local-only 功能或当前 roadmap。
若产品以后需要远端探针，必须新建设计 owner 和独立 roadmap，不能扩张 HP-1 的 loopback 合同。

### 6.8 已确认的本机选择与后续触发条件

| 决策 | 当前合同 | 责任/证据 | 适用票 |
| --- | --- | --- | --- |
| 传输与 root | Panel 容器 `:4000` 发布为宿主 `127.0.0.1:4001`；探针使用 `http://127.0.0.1:4001` plain HTTP。无 TLS 或 mTLS。 | 部署静态配置与 loopback contract test | HP-1 |
| 认证与身份 | 每安装一个静态 bearer token，存于宿主 `0600` 文件；静态 `probe_id` + 每进程 `session_id` 只用于路由和可观测。无 enrollment、CA、证书或撤销生命周期。 | secret 文件权限检查与 redaction test | HP-1 |
| label 权限 | 只有维护者可以设置 `execution:host-only` 和三个可选 capability labels；缺省 capability 集为空。 | 项目维护者维护 Linear 权限 | HP-1、HP-2 |
| heartbeat/lease/deadline | 5 秒 heartbeat、30 秒 lease、30 秒本地保守 deadline。 | 虚拟时钟与 expiry test | HP-1 |
| 宿主边界 | 使用 operator 现有宿主身份、凭据、workspace 和网络；产品不要求专用账号、机器或 VM。 | operator 记录实际选择；产品不做安全认证 | HP-1、HP-5 |
| 崩溃清理 | 正常退出可尝试 best-effort cleanup；异常残留由 operator runbook 处置，无 watchdog 或 process-group 保证。 | operator runbook 与 crash/lease evidence | HP-1、HP-5 |
| 多探针 | 当前只支持单探针；只有以后明确批准多个探针时才启动 HP-4。 | 新需求与独立实现票 | 条件性 HP-4 |

公网传输、WAN、mTLS 和每探针身份生命周期不属于当前功能或 roadmap，不能作为 HP-1 的进入或退出判据。

## 7. 注意事项与风险清单

判据是风险必须有触发条件、后果、可见证据与责任边界。候选处理方式是探针自愈或显式失败；统一推荐
显式失败与 Panel 对账，因为自愈会扩大探针职责。

| 风险处理候选 | 代价 | 判定 |
| --- | --- | --- |
| A. 探针遇错后自动改配置、换 workspace、安装依赖或切回 container | 表面可用性高，但产生隐藏副作用、越权和不可复核路由。 | 淘汰。 |
| B. 探针上报有界事实，由 Panel 按既有词汇分类、展示并对账 | 需要 operator 处理宿主问题，恢复较慢。 | 推荐。 |

| 类别 | 触发条件 | 后果 | 推荐处理 |
| --- | --- | --- | --- |
| 安全：宿主凭据暴露 | probe/Codex compromise，或启动环境继承过宽 | GitHub、Codex、浏览器 session 与本地文件按 operator 所选宿主身份权限暴露 | operator 记录并承担所选账号/机器/VM 边界；最小 env/path allowlist 与 secret redaction；产品不提供 sandbox 或安全认证。 |
| 安全：loopback 或 token 边界扩大 | Panel 端口发布到非 loopback，或静态 token 文件权限宽于 `0600` | 本机外访问或 bearer token 泄漏可导致未授权 claim | root 固定为 `127.0.0.1:4001`；token 文件权限固定为 `0600`；认证失败拒绝请求并 redaction。 |
| 安全：session/event 重放 | 旧 `session_id` 或 event id 被重用 | 过期 session 或重复 terminal | 当前 session/lease fencing + 固定 event UUID 幂等；`probe_id` 不充当认证。 |
| 冲突：同 slot 争用 | container 与 probe 都把同一 candidate 当合格 | host-only 被错误 surface 领取或重复 run | scope→requirement→capability→单探针 session 顺序；DB unique index最后兜底。 |
| 冲突：意外启动多个 probe | 多个 fresh probe 同时 poll | 超出当前单探针合同 | 拒绝额外 session；只有明确启动 HP-4 后才设计 deterministic selection。 |
| 可观测：探针“只报错” | readiness、Codex、gate、lease 或 handoff 失败 | 若自由文本分类会形成第二词汇 | request envelope 与 persisted RunFailure 分层；Panel 统一分类，保留 correlation。 |
| 可观测：terminal ack 丢失 | commit 后连接断开 | probe 误以为失败并创建替代 terminal | 同 event id 无限期按现有 interval 重送，Panel返回原 ack。 |
| 运维：loopback 中断或 laptop sleep | heartbeat 中断 | lease 到期；宿主可能留下仍运行的 Codex 或子进程 | Panel lease 负责 run truth，新 session 不接管旧 lease；正常退出只尝试 best-effort cleanup，异常残留由 operator runbook 处理。 |
| 运维：升级/回滚 | 新旧 Panel 对 host-only label 的解释不同 | 错误顺序可让旧 Panel误领 | Panel-first、label-last；回滚反向并在旧 Panel前清 host-only eligibility。 |
| 运维：探针离线 | host-only issue 已可调度但无 fresh probe | issue 在原状态等待 | 显示 waiting fields，公式阈值告警，不新增 workflow state、不自动转 container。 |
| 边界：容器控制面绕过 | 给 probe 下发 container command/socket 或由 Compose 启动宿主容器 | 破坏既有 no-DinD/no-socket contract | 协议不含 container 操作；宿主包装完全由外部基础设施管理。 |

安全规范要求最小化 tools、credentials、filesystem paths 与 network destinations，并明确提醒 permissive
harness 可能导致数据泄漏或宿主 compromise（`docs/spec-reliability-security.md:188-214`）。本设计不把
host probe 描述为 sandbox。

## 8. 产出落点与文档所有权

判据是未来意图必须由一个 L3 owner 承载，同时现有 owner 保持各自合同，不复制现状。

| 候选 | 代价 | 判定 |
| --- | --- | --- |
| A. 新建本文件作为 proposed L3 owner | 多一个 owner，需要 README、Feature Design Index 与 alignment 注册。 | 推荐；host probe 的四轴、roadmap 和人工用途是独立 concern。 |
| B. 全部扩进 `execution-runtime-design.md` | 文件已有大量 landed container runtime 细节，会把 proposal 与现状混在一起。 | 淘汰。 |
| C. 分散写进九个 owner | 每处只见局部，无法独立评审兼容组合和 roadmap；会重复 claim。 | 淘汰。 |

本文件拥有 proposed host-probe concern。真正实现时必须同步扩展：

- `execution-runtime-design.md`：host pipeline、credential 与 delivery boundary；
- `worker-panel-decoupling-design.md`：identity/session/capability、claim/heartbeat admission；
- `run-failure-classification-design.md`：只在既有 vocabulary 无法表达经批准的新事实时修改；当前方案不需要；
- `observability-errors-design.md`：新增稳定 probe/routing 字段；
- `workflow-config-authority-design.md`：instance/probe topology split；
- `issue-persistence-design.md`：requirement/surface dispatch evidence；
- `workspace-source-layout-design.md`：host-prepared authority/readiness；
- `long_term_direction.zh-CN.md`：从 proposed 变成部分/已落地时更新阶梯状态；
- `compose.md`：只需继续证明没有 DinD/socket；不得为 probe 增加控制面。

本 PR 只注册本文件并同步 documentation alignment，不把 proposal 写成九个 owner 的 landed current truth。

## 9. 双执行面路由与归属

### 9.1 票面需求标记

判据是一个人能在 Linear 上看懂、旧票缺省语义稳定、Panel 能确定性读取、实现不创建第二 project
authority。

| 候选 | 代价 | 判定 |
| --- | --- | --- |
| Label `execution:host-only`（absent/present） | 需要 label 权限治理；值域简单、UI 可见、API 已能读取 labels。 | 推荐。 |
| Linear custom field `execution_surface` | 类型清楚，但要 workspace schema/admin 权限和额外集成。 | 可行但首切淘汰。 |
| description directive | 无需 schema，但自由文本容易误拼、修改审计弱，也与 host-push directive 混淆。 | 淘汰。 |

唯一声明是 label `execution:host-only`；值域只有 absent=`default`、present=`host_only`。有权设置者只有
维护者；host probe、自动化和普通 Codex task tools 无权自标。旧票全部 absent，升级与
回滚时继续当前默认执行面。

### 9.2 单一静态判据表与 capability 匹配

| issue requirement | container worker | host probe |
| --- | --- | --- |
| 未标注 / `default` | **可领**，继续当前 admission | **不可领** |
| `host_only` | **不可领** | 仅 bearer token 已认证的 fresh session、票面 `required_capabilities ⊆ session.capabilities`、workspace readiness 和 project/scope gate 全部通过时**可领**；未要求可选能力时 headless 探针可领 |

票面 capability 载体另有三个候选：独立 allowlisted labels、profile 隐式推导、Linear multi-select 字段。
首切推荐独立 labels：`capability:interactive-session`、`capability:gui-session`、
`capability:manual-pr-handoff`；缺省得到空的可选 `required_capabilities`。它们在 snapshot 中规范化为同名
下划线值，和 `execution:host-only` 正交。profile 隐式推导不可见且会把用途与 profile 耦合，淘汰；
multi-select 类型更强但需要 workspace schema/admin 权限，保留为后续替代载体。capability labels 与
execution label 都只能由维护者设置；probe、自动化和普通 task tools 均无权修改。

这张表是硬 gate，不能由 available slot 或请求到达顺序覆盖。候选方案是：按表和集合包含关系确定性
匹配，或让两个 surface 都 claim 再依靠 lease 去重。推荐前者；lease 只能防重复 run，不能证明执行面
或用途能力合格。路由合同对
现有 claim 是**需扩展**，不是新建：保留 reservation、二次 Linear read、原子 run admission与 assignment，
在副作用前增加 requirement/capability/designated-probe gate。规范 admission 也相应扩展
`docs/spec-orchestration.md`；当前序列化 authority 和 claim 前检查见
`docs/spec-orchestration.md:113-122`、`docs/spec-orchestration.md:183-203`。

### 9.3 与 project + 具体项目监听范围叠加

候选是“project scope 决定 surface”或“两个正交硬 gate 依次相交”。推荐后者：

1. installation `dispatch_scope` 与 enabled project mapping 先决定 issue 是否属于本安装；
2. project 的 active state/profile/dependency/listening gate 决定是否可调度；
3. `execution_requirement` 决定允许的 surface；
4. capability 与当前已认证的单探针 session 决定具体 session。

任何一步失败都不 claim。project/scope 是候选归属硬约束，execution requirement 是 surface 归属硬约束，
二者没有覆盖关系。探针“只监听某项目”不能代替步骤 3。现有配置已经规定 installation scope 不得回写
project mapping或创建第二 context（`docs/workflow-config-authority-design.md:30-34`）；SYM-164 的两级
监听实现也必须消费同一 authority。

### 9.4 离线可见性

候选是让 host-only issue 静默留在 Todo/Ready，或保留工作流状态并给 routing projection/alert。推荐
后者。字段和公式沿用 6.5：`routing_status=waiting_for_probe`、明确 reason、count=0、since timestamp；
达到固定 30 秒阈值（`max(3 × 5 秒 heartbeat, 30 秒 lease)`）告警。运维只能恢复 probe、修复 capability/readiness，
或由有权者移除错误 label；系统不新增状态、不自动转 container。

### 9.5 实际执行面留痕

| 候选 | 代价 | 判定 |
| --- | --- | --- |
| 只在日志推断 | 无 migration，但无法稳定查询、审计或在 Run Detail 展示。 | 淘汰。 |
| `execution_surface` 作为 run admission事实，并复制到 accepted dispatch evidence | 要扩 schema/event serializer，但在 run 建立时已确定，不依赖 terminal 自报。 | 推荐。 |
| 从 workspace path/worker name 推断 | 无 schema，但命名变化会改历史含义。 | 淘汰。 |

字段名是 `execution_surface`，值域是 `panel_local`、`container`、`host_probe`、`ssh`。它由
`RunAdmission` 在创建 run 前一次确定，持久化到 run 查询面，并复制到
`task.accepted.payload.dispatch_context` 作为当次不可变派发证据；Issue Detail 显示 requirement/current
routing，Run list/Run Detail 显示 actual surface。issue snapshot 记录 `execution_requirement`，不记录“将来
一定在哪执行”。这显式扩展现有 snapshot/run association/accepted evidence
（`docs/issue-persistence-design.md:25-31`），不改变 failure vocabulary。

### 9.6 lease、heartbeat、duplicate-run 与同 slot

候选是每个 surface 独立一套 lease/slot，或共享同一 run invariant并把 surface 作为 admission 属性。
推荐后者：

- lease 与 heartbeat 按 assignment owner/session 区分，不按 surface 改变时长语义；host probe 使用固定
  5 秒 heartbeat、30 秒 lease 和 30 秒本地保守 deadline；
- duplicate-run 永远按 issue 判定，不允许 container 和 host_probe 各有一条 running run；
- 同一 deployment 的 current assignment/capacity 仍是全局约束；当前只注册一个 probe，未来多 probe
  必须先启动条件性 HP-4 再定义 selection；
- terminal event 必须匹配当前 assignment/session/lease；过期或 Panel restart 前 identity 明确冲突，现有
  合同见 `docs/worker-panel-decoupling-design.md:150-172`；
- run/event/assignment 使用相同 immutable admission decision，现有 decision 字段及单次消费规则见
  `docs/worker-panel-decoupling-design.md:65-68`。

因此双执行面增加的是 admission 维度与证据，不增加第二种 lease、第二份 issue claim 或 per-surface
running invariant。

## 验收原则

后续实现只有同时满足以下条件才能把本文件的 `design_status` 从 `proposed` 改为 `partial` 或 `landed`：

- HP-1 先以完整纵切交付，不能先横拆基础设施；
- 四格路由与 atomic single-running-run 都有可复核证据；只有明确引入多探针时才要求 HP-4 的确定性选择；
- 八类故障矩阵逐格通过，终态只使用现有闭集，request error 只使用统一 envelope；
- loopback root、bearer token、session identity、capability、workspace readiness、task tools 和 handoff 都保持本文所有权；
- 自动测试不调用 container engine，人工 gate 的 owner 与证据完整；
- 对应 owner 文档和 `docs/documentation-alignment.md` 在同一实现 PR 同步。
