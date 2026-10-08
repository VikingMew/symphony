---
title: Workflow 配置权威来源设计(Workflow Config Authority)
genre: design
domain: [workflow, config]
status: current
language: zh-CN
updated: 2026-10-08
design_status: landed
---

# Workflow 配置权威来源设计

本文维护「项目 settings 与 profiles 在运行时由谁拥有」这一长期契约，以及仓库内 package 文件的角色。
它不拥有 package 格式规范（见 [spec-workflow-config.md](spec-workflow-config.md) §5），
也不拥有启动引导与 Default project 语义（见
[default-project-bootstrap-and-remove-design.md](default-project-bootstrap-and-remove-design.md)）。

## 契约

- PostgreSQL 持久化两个互斥配置 scope。固定的 `app_settings["instance_workflow"]` 保存一份
  installation-wide runtime/profile slice；每个 enabled project 的唯一 `workflows` 记录只保存
  最小 tracker/project slice。`projects` 行是 `tracker.project_slug` 与 repository URL、default branch、
  checkout depth、source strategy、worktree fetch/cleanup 这 7 个字段的唯一 durable authority。
  `WorkflowStore` 在发布边界把 project 行字段注入最小 slice，再与 singleton 组合，并把完整 derived set
  原子发布为内存 snapshot。
- instance singleton 独占 `polling`、`workspace`、`hooks`、`agent`、`codex`、`observability`、
  `analytics`、`server`、`worker`、base prompt 和 `profiles`。project workflow 只接受 tracker 的
  kind/endpoint/assignee/state lists，以及 project required gates/setup/cleanup；它不持久化上述 7 个
  project-owned 字段。
- Settings 按同一 durable ownership 分页：`/settings/runtime` 直接读写 singleton 的 workspace、
  初始化/磁盘阈值、lifecycle hooks 与 Codex model/reasoning/sandbox；`/settings/agents` 直接读写
  singleton 的 base prompt/profiles。两个页面不依赖所选 project，保存后重新发布所有 enabled
  project 的 future runtime snapshot。`/settings/projects` 只提交 project metadata 与
  tracker/repository/source/setup/cleanup slice，不能携带 instance 字段。
- `/settings/projects` 的新增与编辑都先解析 canonical project slice，再在一个 PostgreSQL
  transaction 内写 project metadata（包括 7 个 project-owned 字段）与该 project 的唯一最小 workflow
  row；任一写入失败时两者一起回滚。project workflow 的 `raw_workflow_md` 与 `yaml_config` 来自同一
  canonical minimal slice，
  `prompt_body` 固定为空字符串；base prompt 仍只存在于 instance singleton。
- `WorkflowStore` 组合 singleton 与 project slice 后才交给 schema 解析。schema default 只补齐组合
  workflow 中省略的字段；instance singleton 中显式保存的值保持原样并优先于 default。具体到
  `codex.stall_timeout_ms`，代码 default 是 `600000`，但仍显式保存 `300000` 的 installation 不会因
  代码更新自动改变。该 installation 必须在 `/settings/import` 中 Review import、Confirm，再正常
  Save 为 `600000`，并通过应用层重新读取 current workflow 验证；不得直接更新 SQL。
- `polling.interval_ms` 同样只来自 PostgreSQL current singleton snapshot。显式持久化的 `5000` 或
  `30000` 会原样成为未来 Orchestrator round 的 interval；只有字段省略时 schema 才补代码 default
  `30000`。长期推荐值是 `30000`，仓库 example package 只是 Settings / Import 素材，不证明线上当前
  值。operator 在 `/settings/runtime` 或 `/settings/import` 保存后，重新读取 Settings，并核对
  `/api/v1/state` 的 `polling.poll_interval_ms`；两者必须等于持久 snapshot。不得用手工 SQL UPDATE
  发布该值。
- `RunAdmission.resolve/3` 每次只解析传入的一份 composed workflow snapshot。decision 的 workspace
  authority 来自已选择 execution context；`workspace`、`agent` 与 `codex` limits 只投影 instance
  singleton，repository、default branch、source strategy 与 checkout depth 只投影 project slice。
  issue implementation branch 来自 live issue，operator 为 `nil`。HTTP worker 不得读取 worker-local
  config/path 反填 Panel workflow、decision、payload 或历史。`retry_backoff_ms` 只投影
  `agent.max_retry_backoff_ms`。
- `workflow.states`、`allowed_transitions`、`human_review_states` 与 `tool_policy` 只来自
  `Schema.default_workflow_policy/0`；`tracker.api_key` 只按环境 secret contract 在运行时解析。
- project persistence/export 遇到 instance key、base prompt、profiles、workflow policy、tracker secret
  或 project hook override 时返回 typed rejection，不接受也不静默丢弃。一次性迁移完成后，project
  row 只保留 canonical tracker/project slice 与空 prompt，四个旧 hook columns 已删除。
- `docs/examples/workflow.yml` 与 `docs/examples/profiles.yml` 是示例与显式导入素材：它们记录 package
  格式，供 operator 在 Settings / Import 主动选择，或供明确命名的 test/smoke fixture loader 读取。
  通用无参 loader、source CLI 启动链与 OTP release 启动链都不得隐式读取它们；它们永远不是身份、
  运行时配置或同步源。`Workflow.load/0` 只读取调用方显式设置的 application path，
  `Workflow.load_example_package/0` 才表示有意读取签入示例。
- 示例作为导入素材时仍必须避免携带已知不可用的运行形态；当前 `docs/examples/workflow.yml`
  的 Codex 配置显式使用 `thread_sandbox: "danger-full-access"` 与
  `turn_sandbox_policy.type: "dangerFullAccess"`，使 Settings / Import 的显式导入不依赖
  worker 容器内嵌套 bwrap/user namespace。显式 Settings / Import 会把 combined package 拆成
  singleton 与所选 project slice，并在同一事务内写入。
- 示例中的 `codex.model` 与 `codex.reasoning_effort` 是基于当前代码内 Codex catalog snapshot
  的导入默认值。它们不会反向同步到任何 project，也不会覆盖 operator 已经保存的 PostgreSQL
  current workflow。
- 不存在 package 同步命令、不存在幂等的包覆盖流程、不存在仓库文件与数据库之间的 drift 契约。
  operator 在 Settings 里的改动就是最终改动；仓库示例文件不随之更新不是缺陷。
- Settings / Import 是 portable combined package 的受支持路径：解析文件、按 Instance 与具名 Project
  预览 durable 变化，并在一次确认中原子写入 singleton 与显式选择的 project。预览行与
  `affected_scopes` 直接来自 `WorkflowForm.to_scopes/1` 按 `WorkflowScopes` ownership 拆出的
  Instance/Project slices，与确认时的持久化目标共用同一事实来源；每个 semantic field 只以 canonical
  durable path 出现一次，不维护另一套 prefix/default scope classifier。空库由 operator 在
  Settings / Import 使用同一显式双 scope 导入；拒绝导入、缺少 project target、缺少
  singleton 或缺少 enabled project workflow 时都保持 setup-required。
- portable combined package 可以携带 7 个 project-owned 字段用于 review/export，但它不是这些字段的
  durable authority。确认 import 时先选择目标 project，再在事务开始前对每个显式载体值做规范化比较；
  任一值不同就返回 `{:project_authority_conflict, conflicts}`，其中包含 dotted path、installed value 与
  package value，singleton、project workflow 和已发布 snapshot 均不改变。相同值或省略值可以继续，
  但 workflow 写入前一律剥离这些载体键。project-slice export 只输出最小 durable slice；combined
  export 从目标 project 行重新物化 7 个字段。
- 读取 legacy workflow row 时，载体缺失为 `clean`，相同为 `legacy_duplicate`，不同为 `conflict`。
  组合边界对首次发现或状态发生变化的后两者记录带 project identity、field path 与 status 的结构化
  `project_authority_drift` warning；后台刷新遇到未变化的 drift 不重复告警。随后剥离载体并只注入
  project 行值，不把载体用作 fallback。
  `/settings/projects` 逐字段展示 effective/carrier/status；operator 核对 project 生效值后正常保存该
  project，会同时重建 `yaml_config` 与 `raw_workflow_md` 为最小 slice，使 7 项全部收敛为 `clean`。
- Settings / Import 在生成 staged preview 前转换已知的 legacy Codex command selector：
  `-c` / `--config` 中的 `model`、`model_reasoning_effort` 以及 `-m` / `--model` 会填入尚未显式
  配置的 `codex.model` / `codex.reasoning_effort`，显式 selector 始终优先，随后从 command 删除这些
  参数。staged diff 同时展示 command 清理和 selector 提升；保存到 PostgreSQL current workflow 的
  结果只有结构化 selector 与干净的 app-server launch command。该转换只属于 import，不属于 launch、
  dispatch 或 turn 创建时的 command 解释。
- 修改 split package 中的 implementation prompt 时，worker 交付只验证 rendered prompt 与 package
  artifact。release record 记录 merge 后宿主访问 `/settings/import`、导入并确认 package；预期结果是
  import validation 成功，且保存后的 instance singleton 包含新 prompt。worker 不执行该发布，
  不把宿主路径不可用视为 blocker/retry，也不把 checked-in YAML 报告为 live runtime effect。
- 运行时代码 MUST NOT 从源码 checkout 读取配置。`bin/symphony` 经 `CLI.main/1` 完成依赖与数据库
  准备后直接启动 supervision tree；OTP release 的 `bin/symphony start` 由 release boot script 启动，
  不经过 `CLI.main/1`。两条启动链都不读取或导入签入示例，缺少 durable scope 时保留既有
  setup-required 语义。

## 一次性 legacy 收敛

- 单调 PostgreSQL data migration 对所有仍在 `codex.command` 中携带 model/effort override 的 current
  workflow 应用与 Settings / Import 相同的优先级：现有结构化 selector 优先，缺失 selector 从 legacy
  flag 填入，然后删除 flag。migration 在同一行更新 `yaml_config` 与从相同 config/prompt 重建的
  `raw_workflow_md`；若之前的 scope 收敛 migration 已执行，则同一 migration 更新当前
  `app_settings["instance_workflow"]`，以及尚未 reconciliation 的 candidate 内的 instance config。
  因此 export、Settings 与 runtime 继续读取等价表示；migration 在更严格的 schema validation 生效前完成。

- 单调 PostgreSQL migration 从每个旧 workflow 的 `yaml_config` 与 `prompt_body` 派生 instance
  candidate；project row 中每个非空 hook column 在切片前覆盖对应的 `hooks` 字段。
  `raw_workflow_md` 只按 canonical project slice 重建，从不作为 candidate 来源。候选派生、所有
  workflow rewrite、prompt 清空及 hook columns 删除属于同一个 migration transaction。
- 已存在 `app_settings["instance_workflow"]` 时，migration 只清理 project storage，不覆盖 authority，
  也不创建 conflict。零候选保持 singleton 缺失；一个 distinct canonical candidate（包括多个相同
  candidate）直接成为 singleton。
- 多个 distinct candidate 时，singleton 保持缺失，migration 写入唯一临时值
  `app_settings["legacy_instance_workflow_candidates"]`。该值保留每个 project ID/精确 slug/candidate，
  以及每个不同 dotted path 的所有 contributor；相同 candidate 的每个 project 仍分别保留。
- 临时值不是第三个 authority。runtime、composition、startup、listening 与 dispatch 都不读取它；
  singleton 缺失继续产生 setup-required。只有 typed status 与 reconciliation operation 可以读取它。
- reconciliation 必须选择临时值中的精确 project slug。未知 slug 或 transaction failure 不改变
  singleton 或临时值，原选择可重试；成功 transaction 锁定临时值、写 singleton 并整体删除临时值。
  durable convergence 后的请求返回 typed `already_converged`，不再读取或选择旧 project row。
- 正常进程内 facade 在 durable commit 后调用 `WorkflowStore.force_reload/0`。若发布失败，返回 typed
  `runtime_publication_failed` 且不回滚 singleton；already-converged 重试可以再次发布。OTP release
  eval 只启动 release database lifecycle，不启动业务 supervision tree，也不尝试跨 VM force reload；
  已运行 Panel 由现有一秒 background refresh 发布 durable 结果，未运行 Panel 在启动时加载它。
- Runtime 的 configuration check 展示 typed conflict 中每个 differing path 与全部 contributor；
  Settings project selector 是显式 source selection。未选择 contributor 时 action 禁用，系统不自动
  选择来源；`Use selected project's instance settings` 调用同一个 typed reconciliation operation，
  成功后刷新 singleton、runtime snapshot 与 configuration check。
- 停止状态的 legacy SQLite cutover 在写入已经完成 migration 的 PostgreSQL schema 前应用同一候选与
  rewrite 规则；旧 hook columns 只从 import source 读取，不会在 current project schema 中重建。
- 显式 PostgreSQL smoke 在隔离数据库中为零候选、单候选、多候选等值、多候选不等和已存在 singleton
  五个分支分别重建到 migration 前一版本，写入包含 instance 字段、base prompt 和四个 project hook 的
  legacy fixture，再只向前执行收敛 migration。每个分支验证 project rewrite、setting 选择、hook columns
  删除及 migration 版本；最后通过 release migrator 验证已应用版本 no-op。该边界不直接重复调用
  migration `up/0`，也不调用不可逆的 `down/0`。

## 为何不再同步

同步机制让示例文件成为事实上的配置源：文件同时被标注为 example 与 editable source of truth，
每次改运行时配置都必须回头改仓库 YAML，否则下一次同步会把数据库改回去。这两重身份互相矛盾，
且把「示例」变成了运维入口。取消同步后，示例回归文档与导入素材，配置只有一个权威。

## 后果

- 不再有 `mix symphony.workflow.sync`（写入与只读 `--check` drift 两种模式都不存在），
  也不再有 `--all` 的批量扇出。
- 仓库示例文件允许落后于数据库；这是预期状态，不是缺陷。
- 修改 workflow 配置的正确动作是改 Settings（或在 Settings / Import 导入 package），
  不是编辑仓库 YAML。

## 边界

- 不拥有 workflow schema 与校验规则（[spec-workflow-config.md](spec-workflow-config.md) §5.3 起）。
- 不拥有 Settings UI 布局与 import 预览格式。
- 不拥有启动引导与 Default project 语义。
