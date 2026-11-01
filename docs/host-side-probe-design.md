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

本文所有数字只有三种来源：上述基线中的既有契约、由既有配置值计算的公式，或明确标为需维护者
拍板的建议值。本文不新增生产默认值。

## 待拍板决定：单页摘要

| 决定 | 单一推荐 | 主要代价 | 阻塞的第一张实现票 |
| --- | --- | --- | --- |
| 拓扑 | 探针只从宿主向 Panel root 发起出站 HTTPS；同一协议覆盖局域网和异地网络，root 的固定 discovery relation 返回协议入口。 | 异地使用必须先提供可信 TLS 终止、DNS 与出站可达性；Panel 不主动探测宿主。 | HP-1 |
| 隔离档位 | 首个切片只落在 `Local Worker` 的宿主进程档；远端是“远端宿主上的同类进程”，不把 SSH 或宿主托管容器混入首个协议。宿主身份、凭据与隔离由 operator 选择，产品不提供 sandbox 或安全认证。 | 探针继承 operator 所选宿主边界中可见的文件、会话和凭据，风险由该边界决定。 | HP-1 |
| 路由策略 | 用唯一 Linear label `execution:host-only` 声明必须宿主执行；缺省继续走当前默认执行面。Panel 先做 project/scope gate，再以需求和已验证 capability 确定性匹配，禁止到达顺序决定执行面。 | 需要 label 治理、snapshot/run 证据扩展和旧 Panel 回滚前的停听/清标操作。 | HP-1、HP-2 |
| 配置权威 | Panel 策略进入 installation singleton；root、探针证书路径、宿主 workspace root、Codex 启动参数属于探针部署拓扑；project context 仍只来自现有 PostgreSQL workflow/project 映射。 | 一个部署要同时管理 Panel 设置与宿主本地配置，但两者不能互相覆盖。 | HP-1 |
| 身份与协商 | 一次性 enrollment token 绑定安装与宿主，换取每探针 mTLS 身份；注册协商一个整数 `protocol_version` 和闭集 capability，session 绑定证书、probe id 与启动实例。 | 需要证书签发、轮换、撤销与时间策略；这些运维取值必须先由维护者批准。 | HP-1、HP-3 |

五项推荐可以独立评审。维护者若拒绝其中一项，只阻塞表中对应实现票，不自动推翻其它轴。

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
| 网络暴露 | Panel 部署者提供 HTTPS root；宿主提供出站连接 | TLS/DNS/防火墙各自部署层 | Panel root、CA/客户端证书位置、proxy（如需） | 断网只重试协议动作并最终服从 lease，不开入站端口 |
| GUI/浏览器/交互授权 | 登录宿主的真人 | 宿主桌面 session 与相关账号 | 仅当票面逐项要求时，知道 `gui_session`、`interactive_session` 或 `manual_pr_handoff` capability 是否满足；不保存真人密码 | 要求的 capability 不满足时拒绝 claim；未要求这些能力的 host-only 票可由 headless 宿主领取 |

这一定义复用文件系统硬边界：agent cwd 是当前 run 的 per-issue workspace，路径必须留在配置 root 下
（`docs/spec-reliability-security.md:157-169`）；同时扩展 `workspace_authority` 为已验证的
`host_probe` authority。Panel 不接收、显示或持久化宿主绝对路径，符合 HTTP worker 当前不把本地 path
投影到 Panel 的边界（`docs/worker-panel-decoupling-design.md:65-78`）。

### 1.3 最小协议与最小知情面

探针最小契约只有五个动作：从 root discovery、注册/恢复 session、claim、带 active lease 的 heartbeat、
task event（progress 与 terminal）。现有 worker API 已覆盖注册、claim、heartbeat/renewal 和 task event
（`docs/ARCHITECTURE.md:288-307`）；host probe 不新建另一套 terminal API。

assignment 只需给出 issue/run/assignment 标识、渲染后的 profile prompt、受限 task-tool policy、
required gates、执行需求、实现分支和不含宿主绝对路径的 workspace key。探针不接收 project credential、
Panel database connection、Linear token、容器 socket、source preparation 命令或任意宿主清理指令。

## 2. 连接与配置模型

### 2.1 拓扑决策

判据是 LAN 与 WAN 使用同一行为合同、NAT 后宿主无需入站暴露、Panel 仍是 dispatch authority，并且
不能绕开 Compose 控制面边界。

| 候选 | 代价 | 推荐理由或淘汰理由 |
| --- | --- | --- |
| A. 探针向 Panel root 发起出站 HTTPS，root 提供固定 discovery relation | 需要 TLS、证书和稳定 root；Panel 必须公开受控 endpoint。 | 推荐；同一连接模型覆盖 LAN/WAN，探针不开放端口。 |
| B. Panel 回连每个探针的 HTTP endpoint | 每台宿主需要入站端口、服务发现与防火墙规则；扩大异地暴露面。 | 淘汰。 |
| C. 仅允许 VPN/overlay 地址直连 | 网络边界强，但把特定网络产品变成协议前提，远端接入成本高。 | 可与 A 组合为部署选择，不能替代应用层身份。 |

root 只是 discovery 起点，不携带 project context。反向代理、TLS 与公网边缘仍属于外部基础设施；
现有 Compose 文档也把 public TLS/domain 终止放在服务外部，并禁止服务获得容器控制权
（`docs/compose.md:35-65`）。

### 2.2 配置分层

现有配置权威把 `dispatch_scope`、workspace、agent、codex、worker 与 profiles 放在 installation singleton，
把 Linear project 到 Symphony Project 的 durable mapping 留在 project row
（`docs/workflow-config-authority-design.md:20-40`）。host probe 必须在该模型内扩展。

| 配置 | 候选 | 推荐归属 | 代价/理由 |
| --- | --- | --- | --- |
| Panel root | instance setting / 探针部署拓扑 | 探针部署拓扑 | root 是如何连到本安装，不是业务 routing authority。 |
| 探针身份与认证来源 | 共享 worker token / 每探针身份 | Panel registry + 宿主 secret path | 每探针撤销需要生命周期实现；避免共享 token 长期代表所有宿主。 |
| heartbeat 与 lease | 探针自定 / Panel 下发 | Panel instance singleton 并在注册响应冻结到 session | 单一调度时钟和阈值；探针不能放宽 lease。 |
| workspace root | Panel project setting / 宿主本地配置 | 探针部署拓扑 | Panel 不认识宿主 path；宿主必须证明 cwd 在本地 root 下。 |
| Codex 启动参数 | assignment 任意命令 / 宿主 allowlisted launcher | 宿主本地配置，assignment 只选既有 profile | 降低灵活性，但不允许票面注入任意 launcher。 |
| capability | project context / 注册声明 | 探针声明，Panel 校验为闭集并绑定 session | capability 只描述执行能力，不能选择项目。 |
| host-only label 解释与协议窗口 | 每项目配置 / installation policy | Panel instance singleton | 全安装保持一种语义；不复制 project context。 |

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
| heartbeat/lease | **需扩展** | 只有当前 session、当前 assignment、匹配且未过期 lease 才续约；历史持久化不阻塞 response（`docs/worker-panel-decoupling-design.md:156-169`） | 每次 heartbeat 还要验证未撤销的 probe credential、协商协议和 session capability 摘要；不改变 lease 时钟与续约规则。 |
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
| discovery、注册、认证或协议不兼容，尚未创建 run | typed request error；registration/claim 拒绝 | 无 run；Workers/Probe registry 显示 `last_error.code` |
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
（`docs/long_term_direction.zh-CN.md:544-550`）。它只通过应用层 HTTPS 连接 Panel，不访问 Compose service
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
| 拓扑 | 出站 HTTPS；Panel 回连；VPN-only | HTTPS 要求 TLS/身份；回连要求入站暴露；VPN-only 绑定基础设施。 | 出站 HTTPS。回连扩大攻击面；VPN 可承载 HTTPS 但不能替代协议认证。 |
| 隔离档位 | 宿主进程；宿主托管容器；SSH | 宿主进程继承 operator 所选边界；容器 GUI 成本高；SSH 需要另一套入口。 | 宿主进程。它能直接使用宿主准备的环境，并在票面要求时覆盖 GUI/interactive 用途；另外两档保留独立评审。 |
| 路由策略 | label + capability；仅 project scope；先到先得 | label 需治理；project scope 无法表达 surface；先到先得不可预测。 | `execution:host-only` + capability。后两者不能保证 host-only 不被 container 领取。 |
| 配置权威 | 全放 Panel；全放探针；按策略/拓扑拆分 | 全 Panel 泄漏本地路径；全探针形成 dispatch authority；拆分增加部署文档。 | split authority。Panel 拥有策略，宿主拥有机器事实，现有 project mapping 不变。 |

拓扑与隔离遵守现有外部 runtime 分工和 Compose boundary
（`docs/execution-runtime-design.md:11-27`、`docs/compose.md:35-53`）；路由保留 claim 的二次校验和
single-running-run（`docs/worker-panel-decoupling-design.md:43-75`、
`docs/issue-persistence-design.md:44-56`）；配置权威保持现有 singleton/project 边界
（`docs/workflow-config-authority-design.md:20-40`）。

兼容组合：

- 出站 HTTPS可运行在普通 LAN、VPN/overlay 或公网 TLS 之上。
- 宿主进程 + label/capability routing + split authority 是最小可用组合。
- 同一协议以后可以被宿主托管容器包装，只要启动者在 Compose 外，仍由 host operator 准备资源。
- `execution_surface=ssh` 可共享 run evidence 字段，但 SSH admission 与 credential 仍由独立 owner 设计。

不兼容组合：

- Panel 回连 + NAT 后异地宿主不兼容，除非另建入站网络面；本文不推荐。
- 只按 project scope 路由 + host-only 要求不兼容，因为同项目可同时存在两种票。
- 先到先得 + 双执行面不兼容，因为 container 可能抢走 host-only 票。
- 宿主进程 + 把 `danger-full-access` 当隔离层不兼容；安全边界是 operator 明示选择的宿主身份、凭据和
  隔离方式，产品不增加 sandbox 或安全认证 gate。
- 旧 Panel + 保留活动 `execution:host-only` label 不兼容；旧 Panel 不认识硬 gate，回滚必须先停听并清理活动标记。

### 6.2 版本与 capability 协商

判据是首个窗口只解决 host probe 与 Panel 的兼容拒绝，不建立多代兼容层。

| 候选 | 代价 | 判定 |
| --- | --- | --- |
| SemVer app 版本比较 | 可表达 release，但协议兼容与产品 release 被耦合。 | 淘汰。 |
| 单整数 `protocol_version` + 闭集 capability | 不支持模糊兼容；升级需要明确增加 Panel 支持窗口。 | 推荐。 |
| 仅 capability、无协议版本 | 字段同名异义无法被识别。 | 淘汰。 |

推荐的首个协议标识是有外部含义的 `host-probe` protocol version；初始实现只接受双方完全匹配的
一个整数，不提供旧 shape fallback。capability 的首个闭集是基础能力 `host_execution`、
`codex_app_server`，以及可选用途能力 `interactive_session`、`gui_session`、`manual_pr_handoff`。

能力匹配有两个候选：A 把所有可选用途能力隐式绑定到 `execution:host-only`，实现简单但会排除合格的
headless 宿主并把执行面与用途耦合；B 把执行面和票面 `required_capabilities` 分开，要求
`required_capabilities` 是 session capability 的子集。推荐 B。`execution:host-only` 只选择宿主执行面，
不自动加入任何可选用途能力；headless 探针只要具备两项基础能力，就能领取未要求 GUI、交互 session
或手动 PR 的 host-only 票。新增 capability 必须另票扩展闭集和需求表达，不能靠未知值猜测。

最低 Panel 版本判据不是产品 release 字符串，而是 root discovery 明确广告 host-probe protocol 和
上述 capability schema。拒绝点如下：

- registration：协议不在 Panel 支持集合、未知 capability、缺少两项基础 capability 或证书绑定不匹配，
  均在创建 session 前拒绝；不写 run。缺少可选用途 capability 不拒绝注册。
- claim：session 已协商版本失效、capability digest 改变、credential 撤销、execution requirement 不匹配，
  或票面 `required_capabilities` 不是 session capability 的子集时，在 candidate side effect 前返回 typed
  admission evidence。
- heartbeat：只接受注册时冻结的 protocol/session/capability digest；不匹配不续租，现有 lease 按
  Panel 时钟到期。

灰度顺序是 Panel schema/可见性先上线但 host routing 关闭，随后注册探针并通过 readiness，再启用 label
解释，最后允许 host-only claim。回滚反向执行：先停止 host claim，等待或显式取消当前 assignment，
移除所有 active host-only 标记，再回滚探针，最后才允许回滚 Panel。现有 worker-v1 client 永远不被
推断为 host probe；旧 host probe 因版本不匹配停在 registration，不进入兼容分支。

归属判定：注册/session/capability 属于 `worker-panel-decoupling-design` 的**需扩展**合同；host launcher
与 credential boundary 属于 `execution-runtime-design` 的**需扩展**合同；claim/heartbeat 的拒绝时机
属于 `spec-orchestration` 的**需扩展**规范。终态 event 协议原样复用。

### 6.3 探针身份生命周期

| 方案 | 代价 | 判定 |
| --- | --- | --- |
| 全安装共享长期 registration bearer token | 部署简单；无法单探针撤销，泄漏影响全部宿主，重放窗口无界。 | 淘汰为长期身份；只可作为一次性 enrollment 输入。 |
| 一次性 enrollment + 每探针 mTLS credential + 每启动 session | 需要 CA/证书轮换和撤销状态。 | 推荐。 |
| 每宿主 SSH key 直接作为探针身份 | 复用 SSH 运维，但把应用协议身份与 shell access 绑定。 | 淘汰。 |

推荐生命周期：

稳定 `probe_id` 归属于一个 Symphony installation 与一台宿主，不归属于某个 project。项目资格仍由
Panel 的 dispatch scope 和 project mapping 每次 claim 计算；把 identity 绑定 project 会制造第二份
routing authority，因此淘汰。credential 由 Panel enrollment boundary 签发，部署者只运输一次性输入，
探针本身无权自签或扩大绑定。

| 阶段 | 控制面责任 | 部署者责任 | 探针责任 |
| --- | --- | --- | --- |
| 注册/绑定 | 创建一次性、短时 enrollment，绑定 installation 与预期 host label；校验 CSR 后签发 probe identity。 | 在目标宿主安全放置 enrollment，核对 Panel root/CA/host label。 | 本机生成不可导出 key，完成 mTLS enrollment，不持久化 enrollment token。 |
| session | 以证书 subject 映射稳定 `probe_id`，每次进程启动创建新 `session_id`，冻结 protocol/capability digest。 | 保证同一宿主不会复制 key 到另一台机器。 | 每次启动注册新 session；旧 session 不再续租。 |
| 轮换 | 在旧证书有效且未撤销时签发重叠的新证书，记录 key id；确切 lifetime 由维护者决定。 | 安排无 assignment 窗口并验证新证书。 | 原子切换 credential，重新注册 session；不迁移 active lease。 |
| 撤销 | 按 `probe_id`/key id 撤销，立即拒绝 registration/claim/heartbeat；已运行 lease 不再续期。 | 丢机、离职或怀疑泄漏时执行撤销并停止宿主进程。 | 不尝试 fallback 到共享 token。 |
| 重放防护 | enrollment 单次消费；mTLS possession + session binding；assignment/event 使用现有 UUID 幂等。 | 保护私钥与系统时钟。 | 每个 terminal retry 复用同一 event id，不生成替代 run。 |
| 离职/换机清理 | 撤销旧 key，关闭 session，并在 lease 到期后按现有 reconciliation 收尾。 | 删除本机 key、probe config、Codex/GitHub credential 和 workspace；新机重新 enrollment。 | 退出时只做 best-effort session close；控制面不能依赖它完成。 |

现有 worker registration 使用一个 registration token，后续请求用 worker/session/protocol header
（`docs/persistence_and_auth.md:125-140`）；推荐方案明确替换 host-probe 的长期共享身份，而不兼容性扩展
现有 token。凭据不得进入日志，且只能验证存在而不能打印
（`docs/spec-reliability-security.md:171-175`）。宿主 credential 权限风险至少等同宿主账户；现有共享
`auth.json` 已证明宿主 login 与 worker compromise 共享权限边界
（`docs/execution-runtime-design.md:58-63`）。

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
| 断网 | active run 期间切断 probe→Panel | heartbeat 不达；Panel 时钟令 lease 到期，run 一次性 `worker_process_termination`，旧 assignment event 被 fencing，面板先 stale 后等待合格探针 | AssignmentManager expiry + reconciliation 收口；operator 按宿主 runbook 处理可能残留的进程 | HP-1、HP-4 | 自动断网/lease/event 注入；WAN 恢复人工 gate | 通过 |
| 时钟偏移 | probe 时钟快/慢，Panel 正常 | lease 只看 Panel 时间；client timestamp 仅证据，不提前续租/过期；面板显示 server-observed age | Panel lease owner | HP-4 | 自动虚拟时钟 | 通过 |
| 重复 claim | 两探针同时 claim 同一 host-only issue | 只有 designated probe 可进入 commit；DB 最多一条 running run，另一请求有 typed routing/active-run reason，无重复 accepted event | Orchestrator + atomic run admission | HP-1、HP-4 | 并发测试 | 通过 |
| 探针中途崩溃 | Codex 启动后 kill probe | Panel lease 到期，run 只终结一次，旧 assignment event 被 fencing，不产生重复 running run，面板保留 run/session/probe id 与最后状态 | AssignmentManager expiry 收口 run；Panel reconciliation 对账；operator 按宿主 runbook 处理可能残留的进程 | HP-1、HP-4 | 自动故障注入：断言 lease 到期、单次终态、旧 event 被拒、无重复 running run、面板末态可见 | 通过 |
| 租约过期 | 暂停 heartbeat 超过 lease 后再恢复 | Panel expiry 决定唯一终态；恢复的 heartbeat/event 被拒；新 claim 必须重新读 Linear、建新 run；面板保留最后状态 | AssignmentManager + Panel reconciliation；operator 按宿主 runbook 处理可能残留的进程 | HP-1、HP-4 | 虚拟时钟/协议/fencing 测试 | 通过 |
| Codex 启动失败 | launcher 返回失败或 handshake 超时 | 当前 lease terminal failed；run `runtime_failure`，event evidence 有 stage，gates `not_run`；面板显示 typed failure | probe adapter + RunFailure | HP-1 | 离线 fake app-server | 通过 |
| 交付回执丢失 | Panel 已 commit terminal，ack 响应丢失 | probe 保留同 event id 重送；Panel 返回原 ack，只存在一个 terminal event/run transition；面板不重复通知 | EventWriter/idempotent receipt | HP-1、HP-4 | transport fault test | 通过 |
| 孤儿 run | Panel 重启丢失 assignment 或宿主残留 running row | reconciliation 只写 `run.orphaned` 并显示；operator 明确把 issue 置回可重跑状态后，admission 将旧 run 终结为 `assignment_expired` 再创建一个 run | Panel reconciliation + operator | HP-4 | persistence/restart test + 人工 gate | 通过 |

事件 UUID 去重和 uncertain commit 规则来自 `docs/spec-orchestration.md:305-327`；孤儿 run 只观察、由显式
operator rerun 触发替换来自 `docs/run-failure-classification-design.md:101-105`；原子 running 边界来自
`docs/issue-persistence-design.md:44-56`。

### 6.5 路由运行时状态机

统一面板字段：`execution_requirement`、`routing_status`、`routing_reason`、`eligible_probe_count`、
`selected_probe_id`、`routing_since_at`、`execution_surface`。告警阈值统一为
`routing_wait_seconds >= max(3 × heartbeat_interval_seconds, lease_duration_seconds)`；其中三倍 heartbeat
是既有 session freshness 窗口（`docs/worker-panel-decoupling-design.md:36-43`），其余值来自当前 session
配置，不发明固定秒数。

| 状态/事件 | claim 判定与转换 | 面板字段 | 运维动作 |
| --- | --- | --- | --- |
| 未标注旧票 | 只允许默认 surface；host probe 不领。加 label 后进入 host routing。 | requirement=`default`，status=`eligible_default` | 无；升级/回滚语义不变。 |
| host-only，无在线探针 | 不 claim；fresh eligible 变为 1+ 后进入 ready。 | status=`waiting_for_probe`，reason=`no_online_eligible_probe`，count=0 | 阈值后告警；启动/恢复已 enrollment 探针。 |
| host-only，能力不匹配 | 不 claim；capability/session 修正后重算。 | status=`waiting_for_probe`，reason=`capability_mismatch`，count=0，并列缺项 | 修正宿主能力或移除错误 label；不改项目映射。 |
| host-only，唯一合格探针 | 该 probe 可 claim；成功后 running。 | status=`ready_host_probe`，count=1，selected=probe id | 无。 |
| host-only，多个合格探针 | Panel 对 issue id 与稳定 probe id 做 rendezvous selection；只有 winner 的 claim 可提交。probe 集变化才重算。 | status=`ready_host_probe`，count>1，selected=deterministic id | 检查容量分布；禁止按请求到达顺序选择。 |
| active host run 中 probe stale | 在 lease 过期前不另 claim；expiry 后按失败/重试预算重新进入等待或 ready。 | status=`running_host_probe` 后转 failure/waiting | 恢复网络；不得手工创建第二 run。 |
| Panel 升级，probe 仍旧 | registration/claim 因 protocol 不兼容拒绝；active session 按发布计划先终结。 | status=`incompatible_probe`，reason=`protocol_version` | 先升级 Panel、再探针、最后开 routing。 |
| Panel 回滚 | 必须已 stop host claim、终结 assignment、清除 active host-only label；否则禁止回滚。 | status=`rollback_blocked` 只在新 Panel 运维检查显示 | 按回滚清单消除 blockers；不让旧 Panel误领。 |

`routing_status` 是面板投影，不是 Linear workflow state，也不写回 Todo。状态转换始终先通过既有
installation/project scope，再通过 execution requirement，最后才做 capability 与 deterministic probe
selection。任何一层失败都是硬约束。

### 6.6 迁移与回滚

| 场景 | 迁移结论 | 回滚结论 |
| --- | --- | --- |
| 未标注票 | `execution_requirement=default`，继续走当前 execution mode；不批量加 label。 | 语义完全不变。 |
| 升级时已有 host-only label | 新 Panel 在启用 routing 前先提供只读诊断，确认 label、probe 与 workspace readiness。 | 旧 Panel 不懂 gate；回滚前必须 stop listening、终结 host assignment，并移除/冻结所有 active host-only label。 |
| 合格探针离线 | issue 保持原工作流状态但显示 `waiting_for_probe`，阈值后告警；不转给 container。 | 恢复 probe 或由授权人移除 label；不得自动降级。 |
| 探针升级 | 新 Panel 先支持目标协议，探针在无 assignment 时换 session；旧 session 到期。 | 先停止 host claim、换回仍被 Panel 接受的 probe；若 Panel 已删除旧协议支持则连同 Panel 一起按反向顺序回滚。 |
| execution evidence | 新 run 写 `execution_surface`；历史 run 保持没有该新证据，UI 显示“未记录”，不猜测。 | 停止写新值后旧 UI 忽略额外 event field；若引入 run column，使用单调迁移，不执行 destructive down。 |

这不是兼容层：新协议不解析旧 shape，旧历史也不伪造 surface。唯一保留的是未标注票的既有默认语义。

### 6.7 分阶段、可拆票 roadmap

#### 阶段 A：最小可用纵切

**HP-1（需新票，最小可用切片）— 单探针 host-only 端到端。**

- 目标：探针从 Panel root discovery/enrollment 开始，领取一张 host-only 票，验证宿主准备的 workspace，
  启动 Codex，维持 heartbeat/lease，成功 handoff 或按既有词汇失败，最后释放 assignment 或由 lease 回收。
- 进入判据：本设计批准；维护者批准 TLS/enrollment 形态、credential lifetime、label 名和值域、
  heartbeat/lease 取值；测试 fixture 可提供已准备 workspace 和 fake Codex。
- 依赖票：SYM-173；其余均为本票内纵切，不能先拆配置/claim/Codex 横层。
- 退出判据：一条 offline integration test 从 root discovery 走到 success；同一路径注入 Codex 启动失败、
  probe crash、lease expiry 和 terminal ack loss；Panel 证明一个 run/accepted/terminal、正确 correlation、
  task tools 受限、workspace 越界 fail closed、assignment 释放/回收；probe crash 后 lease 到期、run 只终结
  一次、旧 assignment event 被 fencing、没有重复 running run，且面板可见最后状态。
- 自动可复核：loopback protocol、原子 claim、虚拟 heartbeat/lease、fake app-server、event id retry、
  crash/expiry fencing、`RunFailure` exact classification、UI/state serialization、静态无 container-engine/socket
  检查。
- 必须人工 gate：证书/secret 存放位置，以及 operator 明示其选择的宿主身份、凭据与隔离边界并提供一次
  真实宿主运行证据；不要求 GUI、专用账号、专用机或 VM。责任人是维护者，证据附实现票，阻塞启用
  host routing。
- 运行时副作用：只在测试数据库、loopback Panel 和临时 workspace；不部署、不改真实 label。
- 迁移/回滚：schema 只做前向迁移；feature 默认关闭；停听、终结 lease、关闭 feature 即回滚。

#### 阶段 B：证据、身份与竞争收敛

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

**HP-3（需新票）— 每探针身份全生命周期与协议窗口。**

- 目标：实现 one-time enrollment、mTLS probe identity、session 绑定、轮换、撤销、换机清理与明确协议拒绝。
- 进入判据：HP-1 提供最小注册；维护者批准 CA、lifetime、撤销 SLA 与 key storage。
- 依赖票：HP-1。
- 退出判据：注册、claim、heartbeat 三处分别拒绝不兼容/撤销组合；轮换不接管 active lease；离职/换机
  清理演练有证据。
- 故障场景：enrollment replay、stolen/revoked credential、旧 probe、时钟偏移。
- 自动可复核：证书/nonce/session fixtures、协议矩阵、虚拟时钟、redaction 与无共享-token fallback 检查。
- 必须人工 gate：CA owner、lifetime、撤销响应与丢机流程；维护者签字，阻塞 WAN rollout。
- 运行时副作用：测试 CA 与临时 secret；不触碰真实身份系统。
- 迁移/回滚：Panel 先扩支持窗口，probe 后切换；回滚反向且 active lease 必须先收口。

**HP-4（需新票）— 多探针确定性路由与完整对账。**

- 目标：实现 rendezvous selection、全部八类故障注入、orphan reconciliation 和面板状态机。
- 进入判据：HP-2 evidence 与 HP-3 stable identity 可用。
- 依赖票：HP-2、HP-3。
- 退出判据：多个合格 probe 的到达顺序不改变 winner；八行矩阵全部满足一个 running run、一个 terminal
  truth 和闭集 failure；restart 后无隐式 requeue。
- 故障场景：本文矩阵全部八类。
- 自动可复核：并发/property test、transport fault、restart/persistence、virtual time 和 exact panel projection。
- 必须人工 gate：竞争容量与告警处置演练；维护者负责，证据附演练记录，阻塞多探针 enablement。
- 运行时副作用：仅本地多进程和测试 DB；无外网、无部署。
- 迁移/回滚：关闭 multi-probe admission 后退回单探针；不更改 issue requirement。

#### 阶段 C：真实用例与异地运维

**HP-5（需新票）— 手动 PR 与 GUI 调试验收。**

- 目标：用真实宿主 session 分别完成一次手动 PR lookup/handoff 和一次 GUI debug，人机责任与 evidence
  进入运维指南。
- 进入判据：HP-1 至 HP-4 完成；operator 明示已选择的宿主身份、凭据与隔离边界并提供相应运行证据。
  产品不要求日常账号、专用账号、专用机或 VM 中的特定一种。
- 依赖票：HP-4。
- 退出判据：真人交互不泄漏 credential，Codex 仍只用 task-scoped tools；中途取消、无人响应和 PR receipt
  丢失均有既有终态/恢复路径。
- 故障场景：真人拒绝、interactive session 消失、PR 已存在、handoff evidence 缺失。
- 自动可复核：PR lookup fixture、tool-policy/redaction、cancel/timeout contract；GUI 本身不自动化。
- 必须人工 gate：真实 UI walkthrough 与 PR 审计，由维护者在 operator 已记录的宿主边界内执行并保存
  evidence，阻塞用途对外宣告；该 gate 不评判或强制账号/机器隔离形态。
- 运行时副作用：只使用 operator 明示批准的测试 repo、身份和宿主边界；产品不强制专用账号或机器。
- 迁移/回滚：关闭 host-only routing；不自动删除人工创建的 PR。

**HP-6（需新票）— 异地网络 rollout 与回滚演练。**

- 目标：在获批 WAN/TLS 拓扑上完成灰度、监控、断网和 rollback drill。
- 进入判据：HP-3、HP-5 完成，edge/TLS/egress/incident owner 获批。
- 依赖票：HP-3、HP-5。
- 退出判据：Panel-first/probe-second/label-last 灰度和反向回滚均留证；断网达到阈值会告警且不误路由。
- 故障场景：WAN partition、TLS expiry、DNS failure、Panel rollback。
- 自动可复核：离线配置 lint、协议 matrix、synthetic TLS/transport tests；不要求 container/image validation。
- 必须人工 gate：真实网络、证书与 incident drill；维护者/运维 owner 负责，证据阻塞 production enablement。
- 运行时副作用：只在批准的 staging host；不得调用 Compose 内 container engine。
- 迁移/回滚：按 6.6 表；旧 Panel 回滚前清除 active host-only eligibility。

### 6.8 必须由维护者拍板的选择

| 决策 | 候选与代价 | 推荐 | 责任/证据 | 阻塞票 |
| --- | --- | --- | --- | --- |
| TLS edge | 公网 TLS：易接入、暴露面大；VPN 内 TLS：网络依赖多、暴露面小 | 应用层 mTLS 必须；承载网可公网或 VPN | 维护者 + 运维；网络图和威胁评审 | HP-1、HP-6 |
| enrollment/证书 lifetime | 短：轮换频繁、泄漏窗口小；长：运维少、泄漏窗口大 | 保持可配置，不在调研中发明默认数值 | 安全 owner；批准的 lifetime/SLA | HP-1、HP-3 |
| key storage | OS keychain/TPM：集成成本高；权限受限文件：便携但防拷贝弱 | 优先 OS keychain/TPM，可接受路径必须书面批准 | 安全 owner；宿主检查证据 | HP-3 |
| host-only label 权限 | 所有 issue editor：灵活但误标风险高；维护者/受限自动化：控制强 | 维护者和显式受限自动化 | 项目维护者；Linear 权限截图/规则 | HP-1、HP-2 |
| heartbeat/lease 取值 | 短：恢复快、WAN 抖动敏感；长：稳定但故障回收慢 | 复用 worker 参数模型，具体值按 WAN 测试批准 | 运维 owner；断网/抖动报告 | HP-1、HP-4 |
| 宿主残留进程 runbook | 临时人工处置：准备少但责任与证据易遗漏；书面 operator runbook：运维成本较高但责任明确 | 书面 runbook 记录发现、处置与升级责任；不作为产品保证或探针准入条件 | operator 编写，维护者确认责任人与演练记录 | HP-5 |
| 告警接收与升级 | Panel-only：简单易漏；外部告警：可靠但需集成 | Panel 字段必做，外部告警由生产 rollout gate 决定 | 运维 owner；on-call 记录 | HP-2、HP-6 |
| operator-owned 宿主边界记录 | 日常账号：准备少、暴露面按现有身份；专用账号/专用机/VM：准备多、边界更窄 | 产品不替 operator 选择；要求明确记录所选身份、凭据、workspace、网络边界与一次运行证据 | operator 记录，维护者确认记录完整；不做产品安全认证 | HP-1、HP-5 |

表内每项都给出完整候选、代价和推荐；实现票不得把这些值改成隐式默认。

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
| 安全：异地网络暴露 | Panel root 公网可达且 TLS/identity 配置错误 | 探针冒充、metadata 泄漏、claim 滥用 | 出站 HTTPS + mTLS + 单 probe revocation；不开放 probe 入站端口。 |
| 安全：冒充与重放 | enrollment 重用、证书复制、event id 改写 | 假 session 或重复 terminal | enrollment 单次消费、key/session 绑定、固定 event UUID 幂等、撤销。 |
| 冲突：同 slot 争用 | container 与 probe 都把同一 candidate 当合格 | host-only 被错误 surface 领取或重复 run | scope→requirement→capability→deterministic probe 顺序；DB unique index最后兜底。 |
| 冲突：多个 probe 到达顺序 | 多个 fresh probe 同时 poll | 首到者获得工作，路由不可复核 | rendezvous winner；非 winner 返回 typed admission reason。 |
| 可观测：探针“只报错” | readiness、Codex、gate、lease 或 handoff 失败 | 若自由文本分类会形成第二词汇 | request envelope 与 persisted RunFailure 分层；Panel 统一分类，保留 correlation。 |
| 可观测：terminal ack 丢失 | commit 后连接断开 | probe 误以为失败并创建替代 terminal | 同 event id 无限期按现有 interval 重送，Panel返回原 ack。 |
| 运维：断线重连 | WAN partition 或 laptop sleep | lease 到期；宿主可能留下仍运行的 Codex 或子进程 | Panel lease 负责 run truth，新 session 不接管旧 lease；正常退出只尝试 best-effort cleanup，异常残留由 operator runbook 处理。 |
| 运维：升级/回滚 | Panel/probe protocol 窗口不一致 | registration/claim 停止；错误顺序可让旧 Panel误领 | Panel-first、label-last；回滚反向并在旧 Panel前清 host-only eligibility。 |
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

唯一声明是 label `execution:host-only`；值域只有 absent=`default`、present=`host_only`。有权设置者是维护者
和经维护者明确授权的受限自动化；host probe 和普通 Codex task tools无权自标。旧票全部 absent，升级与
回滚时继续当前默认执行面。

### 9.2 单一静态判据表与 capability 匹配

| issue requirement | container worker | host probe |
| --- | --- | --- |
| 未标注 / `default` | **可领**，继续当前 admission | **不可领** |
| `host_only` | **不可领** | 仅 fresh session、两项基础 capability、票面 `required_capabilities ⊆ session.capabilities`、workspace readiness 和 project/scope gate 全部通过时**可领**；未要求可选能力时 headless 探针可领 |

票面 capability 载体另有三个候选：独立 allowlisted labels、profile 隐式推导、Linear multi-select 字段。
首切推荐独立 labels：`capability:interactive-session`、`capability:gui-session`、
`capability:manual-pr-handoff`；缺省得到空的可选 `required_capabilities`。它们在 snapshot 中规范化为同名
下划线值，和 `execution:host-only` 正交。profile 隐式推导不可见且会把用途与 profile 耦合，淘汰；
multi-select 类型更强但需要 workspace schema/admin 权限，保留为后续替代载体。capability labels 与
execution label 使用同一授权设置者；probe 和普通 task tools 均无权修改。

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
4. capability 与 deterministic probe selection 决定具体 session。

任何一步失败都不 claim。project/scope 是候选归属硬约束，execution requirement 是 surface 归属硬约束，
二者没有覆盖关系。探针“只监听某项目”不能代替步骤 3。现有配置已经规定 installation scope 不得回写
project mapping或创建第二 context（`docs/workflow-config-authority-design.md:30-34`）；SYM-164 的两级
监听实现也必须消费同一 authority。

### 9.4 离线可见性

候选是让 host-only issue 静默留在 Todo/Ready，或保留工作流状态并给 routing projection/alert。推荐
后者。字段和公式沿用 6.5：`routing_status=waiting_for_probe`、明确 reason、count=0、since timestamp；
达到 `max(3 × heartbeat interval, lease duration)` 告警。运维只能恢复 probe、修复 capability/readiness，
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

- lease 与 heartbeat 按 assignment owner/session 区分，不按 surface 改变时长语义；
- duplicate-run 永远按 issue 判定，不允许 container 和 host_probe 各有一条 running run；
- 同一 deployment 的 current assignment/capacity 仍是全局约束；未来多 probe 先经 deterministic selection，
  再进入同一原子 admission；
- terminal event 必须匹配当前 assignment/session/lease；过期或 Panel restart 前 identity 明确冲突，现有
  合同见 `docs/worker-panel-decoupling-design.md:150-172`；
- run/event/assignment 使用相同 immutable admission decision，现有 decision 字段及单次消费规则见
  `docs/worker-panel-decoupling-design.md:65-68`。

因此双执行面增加的是 admission 维度与证据，不增加第二种 lease、第二份 issue claim 或 per-surface
running invariant。

## 验收原则

后续实现只有同时满足以下条件才能把本文件的 `design_status` 从 `proposed` 改为 `partial` 或 `landed`：

- HP-1 先以完整纵切交付，不能先横拆基础设施；
- 四格路由、确定性多探针选择与 atomic single-running-run 都有可复核证据；
- 八类故障矩阵逐格通过，终态只使用现有闭集，request error 只使用统一 envelope；
- root/discovery、identity、capability、workspace readiness、task tools 和 handoff 都保持本文所有权；
- 自动测试不调用 container engine，人工 gate 的 owner 与证据完整；
- 对应 owner 文档和 `docs/documentation-alignment.md` 在同一实现 PR 同步。
