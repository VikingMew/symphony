---
title: Workflow 配置权威来源设计(Workflow Config Authority)
genre: design
domain: [workflow, config]
status: current
language: zh-CN
updated: 2026-09-10
design_status: landed
---

# Workflow 配置权威来源设计

本文维护「项目 settings 与 profiles 在运行时由谁拥有」这一长期契约，以及仓库内 package 文件的角色。
它不拥有 package 格式规范（见 [spec-workflow-config.md](spec-workflow-config.md) §5），
也不拥有 first-run 引导与 Default project 语义（见
[default-project-bootstrap-and-remove-design.md](default-project-bootstrap-and-remove-design.md)）。

## 契约

- 每个 enabled project 的 PostgreSQL current workflow 是运行时唯一权威。orchestrator、Panel、
  Settings、prompt builder、diagnostics 读取的都是由该记录发布的快照，不读取源码 checkout 里的配置文件。
- `docs/examples/workflow.yml` 与 `docs/examples/profiles.yml` 是示例与导入素材：它们记录 package
  格式、提供一次性导入的便利来源，永远不是同步源。
- 不存在 package 同步命令、不存在幂等的包覆盖流程、不存在仓库文件与数据库之间的 drift 契约。
  operator 在 Settings 里的改动就是最终改动；仓库示例文件不随之更新不是缺陷。
- Settings / Import 是把 package 文件带进 project 的唯一受支持路径：解析文件、预览合并后的 draft、
  保存时写入该 project 的 current workflow。空库冷启动可以一次性提供同样的导入；拒绝导入则保持
  setup-required。
- 运行时代码 MUST NOT 从源码 checkout 读取配置。

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
