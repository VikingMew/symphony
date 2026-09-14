---
title: Workflow 配置权威来源设计(Workflow Config Authority)
genre: design
domain: [workflow, config]
status: current
language: zh-CN
updated: 2026-09-14
design_status: landed
---

# Workflow 配置权威来源设计

本文维护「项目 settings 与 profiles 在运行时由谁拥有」这一长期契约，以及仓库内 package 文件的角色。
它不拥有 package 格式规范（见 [spec-workflow-config.md](spec-workflow-config.md) §5），
也不拥有 first-run 引导与 Default project 语义（见
[default-project-bootstrap-and-remove-design.md](default-project-bootstrap-and-remove-design.md)）。

## 契约

- PostgreSQL 持久化两个互斥配置 scope。固定的 `app_settings["instance_workflow"]` 保存一份
  installation-wide runtime/profile slice；每个 enabled project 的唯一 `workflows` 记录只保存
  tracker/project slice。`WorkflowStore` 在发布边界先组合 singleton 与每个 project slice，再把完整
  derived set 原子发布为内存 snapshot。
- instance singleton 独占 `polling`、`workspace`、`hooks`、`agent`、`codex`、`observability`、
  `analytics`、`server`、`worker`、base prompt 和 `profiles`。project workflow 只接受 tracker 的
  kind/endpoint/project slug/assignee/state lists，以及 repository/source/setup/cleanup 字段。
- `workflow.states`、`allowed_transitions`、`human_review_states` 与 `tool_policy` 只来自
  `Schema.default_workflow_policy/0`；`tracker.api_key` 只按环境 secret contract 在运行时解析。
- project persistence/export 遇到 instance key、base prompt、profiles、workflow policy、tracker secret
  或 project hook override 时返回 typed rejection，不接受也不静默丢弃。一次性迁移完成后，project
  row 只保留 canonical tracker/project slice 与空 prompt，四个旧 hook columns 已删除。
- `docs/examples/workflow.yml` 与 `docs/examples/profiles.yml` 是示例与导入素材：它们记录 package
  格式、提供一次性导入的便利来源，永远不是同步源。
- 示例作为导入素材时仍必须避免携带已知不可用的运行形态；当前 `docs/examples/workflow.yml`
  的 Codex 配置显式使用 `thread_sandbox: "danger-full-access"` 与
  `turn_sandbox_policy.type: "dangerFullAccess"`，使 Settings / Import 与空库冷启动素材不依赖
  worker 容器内嵌套 bwrap/user namespace。显式 Settings / Import 会把 combined package 拆成
  singleton 与所选 project slice，并在同一事务内写入。
- 示例中的 `codex.model` 与 `codex.reasoning_effort` 是基于当前代码内 Codex catalog snapshot
  的导入默认值。它们不会反向同步到任何 project，也不会覆盖 operator 已经保存的 PostgreSQL
  current workflow。
- 不存在 package 同步命令、不存在幂等的包覆盖流程、不存在仓库文件与数据库之间的 drift 契约。
  operator 在 Settings 里的改动就是最终改动；仓库示例文件不随之更新不是缺陷。
- Settings / Import 是 portable combined package 的受支持路径：解析文件、预览合并后的 draft、
  保存时分别写入 singleton 与所选 project。空库冷启动使用同一显式双 scope 导入；拒绝导入、缺少
  singleton 或缺少 enabled project workflow 时都保持 setup-required。
- 修改 split package 中的 implementation prompt 时，worker 交付只验证 rendered prompt 与 package
  artifact。release record 记录 merge 后宿主访问 `/settings/import`、导入 package 并 Save；预期结果是
  import validation 成功，且保存后的 instance singleton 包含新 prompt。worker 不执行该发布，
  不把宿主路径不可用视为 blocker/retry，也不把 checked-in YAML 报告为 live runtime effect。
- 运行时代码 MUST NOT 从源码 checkout 读取配置。

## 一次性 legacy 收敛

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
- 停止状态的 legacy SQLite cutover 在写入已经完成 migration 的 PostgreSQL schema 前应用同一候选与
  rewrite 规则；旧 hook columns 只从 import source 读取，不会在 current project schema 中重建。

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
- 不拥有 first-run 引导与 Default project 语义。
