---
title: Symphony 文档体系设计
genre: design
domain: [meta, documentation]
status: current
language: zh-CN
updated: 2026-08-07
design_status: landed
---

## 1. 背景与问题

迁移前,17 篇文档平铺在 `elixir/docs/` + 根级 SPEC/ARCHITECTURE/CODE_STRUCTURE,存在四个结构病(plan 227 后已按本设计归位):

1. **无分类结构**:设计/规范/参考/指南/路线图 5 种体裁混在一个目录,找文档靠文件名记忆。
2. **语言双轨混乱**:规范用 EN、设计用 zh-CN,无成文规则;CODE_STRUCTURE 是唯一 EN+zh 双份,同步维护成本高。
3. **无权威分层**:SPEC(2184 行)与设计文档冲突时谁赢没有规则;documentation_alignment 是历史补丁不是持续机制。
4. **无验证钩子**:全仓库唯一有机器校验的是 exec-plans(`exec_plans.check`);文档漂移靠人工 grep。

## 2. 参考模型

采用 letsinflu-server 的 **L0-L5 分层模型**(物理平铺 + 概念分层 + 命名约定 + 布局检查脚本):

- **L0 Governance**:charter / decisions(ADR)/ execplan(历史记录)
- **L1 System architecture**:只讲拓扑、信任/数据边界、跨切不变量、长期方向;禁止包级/功能级细节
- **L2 Backend design**:包布局与规则、HTTP/auth/storage/测试约定、功能设计索引;不写拓扑/方向叙事
- **L3 Feature designs**:`*-design.md` 一主题一篇,每篇 owner 自己的 contract
- **L4 Normative contracts**:参考表与线格式契约,无叙事
- **L5 Operational guides**:runbook,以"步骤能跑通"为判据

核心规则:**每个 contract 有且只有一个 owning 文档,其他文档链接不复制;新文档必须归入恰好一层。**

## 3. Symphony 层模型

当前形态(根级 `docs/`,无 `elixir/` 子目录;elixir/ 提升已由 exec plan 226 完成):

| 层 | 文档 | 说明 |
|---|---|---|
| L0 | `AGENTS.md`(根)、`docs/README.md`、`docs/decisions.md`、`docs/documentation-alignment.md`、`docs/documentation-system-design.md`、`docs/exec-plans/` | 治理:贡献规则、决策日志(ADR)、一致性矩阵、本设计、计划生命周期 |
| L1 | `docs/ARCHITECTURE.md`、`docs/long_term_direction.zh-CN.md` | 拓扑/边界/不变量/方向;收敛为系统级,不含包级细节 |
| L2 | `docs/design.md` | 包布局与约定 + **Feature Design Index**;原 CODE_STRUCTURE 已并入 |
| L3 | `docs/*-design.md`(8 篇,已规范化命名) | workflow-page-design、worker-panel-decoupling-design、workspace-source-layout-design、codex-linear-interaction-design、codex-linear-implementation-workflow-design、codex-linear-task-refinement-workflow-design、dashboard-color-system-design、hot-update-design;每篇标 `design_status: landed/partial/proposed` |
| L4 | `docs/spec.md`(总纲)+ `docs/spec-*.md`(8 个域契约)、`docs/logging.md`、`docs/token_accounting.md`、`docs/persistence_and_auth.md`、`docs/test_database_isolation.md` | SPEC 已按域拆分(§4 域模型、§5-6 工作流/配置、§7-9 编排、§10/12 Agent Runner、§11 Linear、§13 观测、§14-15 可靠性/安全、§16 参考算法、§17-18 一致性) |
| L5 | `docs/user-guide.zh-CN.md`、`docs/deployment.md` | 操作指南 |

## 4. 命名约定

- 功能设计:`<concern>-design.md`(一主题一篇)
- 规范契约:`<domain>-contract.md` 或固定名(`spec.md`、`logging.md`)
- 层锚固定名:`AGENTS.md`、`decisions.md`、`architecture.md`、`design.md`、`README.md`
- 指南:`<name>-guide.md` 或固定名(`deployment.md`、`user-guide.zh-CN.md`)
- **废除双份翻译**(CODE_STRUCTURE.zh-CN 模式):单份权威 + frontmatter `translation_of:` 链接

## 5. frontmatter 规范

每篇文档头部(与 exec-plans 同构,由 `mix docs.check` 强制):

```yaml
---
title: 文档标题
genre: spec | architecture | design | reference | guide | roadmap | meta
domain: [主题标签, ...]      # 自由扩展
status: current | superseded | deprecated   # 现状文档
design_status: landed | partial | proposed  # 仅 L3 设计文档
language: en | zh-CN
owner: 模块/函数锚点          # 现状文档必须可验证
updated: YYYY-MM-DD
translation_of: <path>       # 可选
---
```

## 6. 精确性机制(只描述现状如何保证精确)

1. **层规则隔离未来**:L2/L4/L5 只描述现状;未来意图只进 L3 且标 `design_status`。落地时把现状同步进 L4,设计文档保留为历史意图。
2. **`mix docs.check`**(仿 `exec_plans.check`):校验每篇文档有 frontmatter、genre 合法、层归属合法、在索引注册、`owner` 代码锚点存在(对 reference 文档 grep 模块/函数)。
3. **单一事实源**:每个契约一个 owner 文档,其他文档链接不复制(219 的"共享配置"漂移即两处复制产物)。
4. **语言规则成文**:L1/L4 = EN(与代码一致);L3/L5 可 zh-CN 但声明 `language:`;禁止双份同步翻译。

## 7. 可扩展性

- 新功能 → 一篇 `*-design.md`(L3)→ 入 `design.md` Feature Design Index → 落地后同步 L4 contract → 归档 exec-plan。
- 新领域(worker、webhooks…)只加 `domain` 标签与文档文件,不破坏层结构。
- genre 集合固定;新增 genre 需修订本文档(meta 宪法)。

## 8. 迁移路径(exec plans)

- **225 文档元体系**(✅ 已完成):层模型写入 AGENTS.md、`docs/README.md` 导航、`decisions.md` 建立、`mix docs.check` 工具。
- **226 elixir/ 提升为根**(✅ 已完成):代码移根、README 合并、Makefile/mise 从根跑、CI 路径更新。
- **227 文档物理归位**(✅ 已完成):全部文档进根 docs/、锚点去 elixir/ 前缀、SPEC 按域拆分、CODE_STRUCTURE 并入 design.md、语言规则落地、全量贴 frontmatter。

顺序逻辑:225 纯设计不依赖路径 → 226 动代码(锚点一次改对)→ 227 物理归位(不二次移动)。精确性机制在 225 就位,迁移全程有 `docs.check` 护航。
