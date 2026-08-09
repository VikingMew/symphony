---
title: 巡检 Profile 标准化设计(Operator Profiles Contract)
genre: design
domain: [workflow, operator, profiles]
status: current
language: zh-CN
updated: 2026-08-09
design_status: landed
---

# 巡检 Profile 标准化设计

## 1. 背景

Symphony 的 workflow 里有两类"巡检型"operator profile:**nap**(工程审计)与 **day_dreaming**(方向探索)。二者都是只读巡检:不改代码、不改文档、不建 commit/PR,只通过受限的 issue 创建工具为每个发现建一个 Backlog Linear issue。

当前实现存在**三处来源漂移**:

| 来源 | nap | day_dreaming | 问题 |
| --- | --- | --- | --- |
| `lib/symphony_elixir/config/schema.ex` 默认值 | ✅(旧版 prompt) | ✅ | nap 默认 prompt 是旧版,未包含 2026-08-09 确立的"冗余错误处理/门控、不合理依赖、降复杂度 + Linus & Carmack 逐条对照"标准 |
| DB `workflow_versions.yaml_config`(每 project 一份) | ✅(Koroni 已改新版) | ✅ | 与代码默认值可能不一致;新标准只进了 Koroni,Default 及其他 project 仍是旧版 |
| `profiles.yml` 包文件 | ❌ **缺失** | ❌ **缺失** | import/export 包不完整,巡检 profile 无法随包迁移 |

漂移的后果:同一个 profile 在不同 project 里行为不同;审计标准升级要改三处且易漏;包文件迁移丢失巡检 profile 定义。

## 2. 目标

把 nap / day_dreaming 标准化为**契约化 operator profiles**:

- 一份**权威的标准 prompt 模板**(代码默认值),所有来源以它为准;
- `profiles.yml` 补齐 nap / day_dreaming,包迁移完整;
- 新 DB workflow 初始化时从标准模板落库;已有 DB 允许 project 覆盖,但覆盖以标准为基线;
- nap 默认 prompt 升级为 2026-08-09 确立的新标准(见 §3.1)。

## 3. 巡检 Profile 契约

### 3.1 nap — 工程审计

**定位**:降低代码复杂度。查找三类问题:

1. **冗余**:重复逻辑/近似函数/复制粘贴块;冗余错误处理(重复 rescue/retry/wrap、对已校验数据的重复防御、掩盖真实失败的 catch-all);冗余门控(多余 feature flags、永假条件、跨层重复的权限/能力检查)。
2. **不合理的互相依赖**:偶然耦合(非有意)、循环模块依赖、god modules、隐藏共享状态(ETS/全局/进程字典)、字符串判别行为、单一事实双份表示、只有单一实现的间接层。
3. **死重**:投机抽象、无人读的配置、兼容 shim、注释掉的代码。

**判定标准**:每个候选必须对照 Linus & Carmack 原则并声明违反了哪条:

- Linus: remove complexity, keep good taste — 让系统更简单优于更复杂;拒绝架构天文抽象;代码必须挣得存在。
- Linus: talk is cheap, show me the code — 具体、可工作、最小的改动优于设计论文。
- Carmack: minimize the number of things that can go wrong — 每个 flag/抽象/catch-all 都是可能出错的东西;单一事实不得双份表示。
- Carmack: hard to make simple is still worth it — 难懂的代码难正确;简化,而不是用文档绕。
- Explicit errors over silent tolerance — 失败必须可见且有类型;不得吞崩溃保 pipeline 存活且无记录。

**产出格式**:每个违反至少一条标准的问题建一个 Backlog Linear issue,包含:简洁标题、证据(file/line 或代码摘录)、违反哪条标准及原因、复杂度影响、降复杂度的修复方向。

### 3.2 day_dreaming — 方向探索

**定位**:对比"实现现状 vs 产品方向",识别值得做的功能/优化机会。

**判定标准**:机会必须有代码/文档证据支撑;与长期方向文档一致;不重复已有 Backlog issue。

**产出格式**:每个机会建一个 Backlog Linear issue,包含:简洁标题、证据来源、为什么重要、建议方向、粗略影响。

### 3.3 公共契约(两者一致)

- executor: `codex_agent`
- prompt mode: `replace`
- allowed_updates: comment=false / description=false / result=false / target_states=[]
- 只读:不改代码、不改文档、不建 commit/PR
- issue 创建走受限工具(`issue_create`),且仅 `nap` / `day_dreaming` profile 允许
- 干净 worktree 前后检查(脏树即失败)

## 4. 单一权威来源

**代码默认值(`schema.ex`)是标准 prompt 的唯一权威来源**。其余来源的生成/迁移路径:

1. **代码默认值** `schema.ex`:nap / day_dreaming 标准 prompt(§3)落在此处。
2. **profiles.yml**:从标准模板生成,补 nap / day_dreaming 段,随 import/export 包迁移。
3. **DB workflow 初始化**:新建 workflow 时,巡检 profile 默认值从标准模板填充;显式覆盖允许,但 schema/UI 提供"重置为标准"路径。

改动巡检标准时,只改代码默认值一处;profiles.yml 由导出流程再生成;DB 存量通过"重置为标准"收敛。

## 5. 非目标

- 不做巡检调度/定时触发(有独立 plan 空间)。
- 不改 `issue_create` 工具本身。
- 不改变 implementation/refinement/merge 三类的 profile 契约。
- 不做跨 project 的 prompt 强制同步(覆盖允许,仅提供基线)。

## 6. 验收

- [ ] `schema.ex` 中 nap 默认 prompt 含 §3.1 全部要素(冗余错误处理/门控、依赖、死重、Linus & Carmack 逐条、产出格式)。
- [ ] `schema.ex` 中 day_dreaming 默认 prompt 含 §3.2 要素。
- [ ] `profiles.yml` 含 nap / day_dreaming 段,内容与代码默认值一致。
- [ ] 新建 workflow 的巡检 profile 默认值来自标准模板(测试覆盖)。
- [ ] import/export 包往返后 nap / day_dreaming 完整保留(测试覆盖)。
- [ ] `mix specs.check` 通过。
- [ ] `make all` 通过。

## 7. 后续衔接

实现拆分见 exec plan 248(active)。巡检调度、结果去重、dashboard 按钮等留待后续 plan。
