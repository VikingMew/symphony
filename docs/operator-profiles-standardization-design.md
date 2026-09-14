---
title: 巡检 Profile 标准化设计(Operator Profiles Contract)
genre: design
domain: [workflow, operator, profiles]
status: current
language: zh-CN
updated: 2026-09-14
design_status: landed
---

# 巡检 Profile 标准化设计

## 1. 背景

Symphony 的 workflow 里有两类"巡检型"operator profile:**nap**(工程审计)与 **day_dreaming**(方向探索)。二者都是只读巡检:不改代码、不改文档、不建 commit/PR,只通过受限的 issue 创建工具为每个发现建一个 Backlog Linear issue。

profile contract 有三种表示，但 durable authority 只有一处：

| 来源 | nap | day_dreaming | 问题 |
| --- | --- | --- | --- |
| `lib/symphony_elixir/config/schema.ex` 默认值 | ✅(旧版 prompt) | ✅ | nap 默认 prompt 是旧版,未包含 2026-08-09 确立的"冗余错误处理/门控、不合理依赖、降复杂度 + Linus & Carmack 逐条对照"标准 |
| DB `app_settings["instance_workflow"]`（installation 一份） | ✅ | ✅ | 保存显式配置；所有 project 使用同一份 singleton profile policy |
| `profiles.yml` 包文件 | ✅ | ✅ | portable combined package 的 import/export 表示，不是 runtime authority |

project workflow 不保存 base prompt 或 profiles，也不存在 project profile override。

## 2. 目标

把 nap / day_dreaming 标准化为**契约化 operator profiles**:

- 一份**权威的标准 prompt 模板**(代码默认值),所有来源以它为准;
- `profiles.yml` 补齐 nap / day_dreaming,包迁移完整;
- 新 DB 初始化或显式 package import 时把全部 profiles 与 base prompt 写入 instance singleton;
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


**审计方法论（2026-08-16 增补，源自 DeepSeek Harness 冗余删除实践提炼）**：

nap 是「提出删除/优化方向的方法」，不是删除本身。发现路径分两层：**机械扫描 + 人工审查**。

1. **机械扫描前置**（执行时先跑，工具输出作为证据源，与手写审查互补）：
   - `mix xref graph` —— 无消费者导出 / 未使用函数；
   - `mix deps.tree` + 未使用依赖检查 —— 依赖冗余；
   - credo duplicate code / cyclomatic complexity —— 重复逻辑；
   - `mix dialyzer` —— 死代码（unused_fun 等；OTP28 有误报，输出必须人工复核）。
   工具输出只是线索，每条候选仍需对照 Linus & Carmack 逐条判定后才建 issue。

2. **新增审计维度**（在原有三类问题之上）：
   - **豁免清单 stale 审计**：`.dialyzer_ignore.exs` / credo 豁免 / `@tag :skip` 测试 / 被禁 lint 规则——条目对应代码是否还在？能否收紧？能否删掉整条豁免基线？（清理后豁免清单应能收缩到空）
   - **无消费者公共 API / 事件**：公共导出、GenServer cast/call、事件 topic 无真实消费者（以 xref graph 佐证）。
   - **手写维护型文档生成化**：文档事实是否已有源码单一事实源（schema.ex 配置项、模块清单、索引）——手写即漂移源；过期文档建议归档而非物理删除。
   - **防复发门禁**：修复方向优先「引入门禁 + 清零后删豁免基线」，而非一次性清理。

3. **产出格式升级**：每个 issue 除原有字段（标题/证据/违反标准/复杂度影响/修复方向）外，增加：
   - 发现路径（机械扫描输出 / 人工审查）；
   - 验证方式：建议删除后如何证明行为不变（`make all` / 相关测试 / dialyzer）。

4. **防误报纪律**：
   - 工具输出必须人工复核（dialyzer OTP28 unused_fun 误报已知）；
   - 区分「纯删除」与「重组迁移」：能力仍在使用但归属错位 → 建议重组而非删除；
   - 拿不准的候选写「Keep as-is」，不堆噪音。

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
2. **profiles.yml**:从标准模板生成,补 nap / day_dreaming 段,随 combined import/export 包迁移。
3. **DB singleton 初始化**:新建 instance workflow 时从标准模板填充；显式 singleton 配置允许覆盖。

改动巡检标准时,只改代码默认值一处；profiles.yml 由导出流程再生成；DB singleton 通过显式导入收敛。

## 5. 非目标

- 不做巡检调度/定时触发(有独立 plan 空间)。
- 不改 `issue_create` 工具本身。
- 不改变 implementation/refinement/merge 三类的 profile 契约。
- 不提供 per-project prompt/profile override；singleton 保存影响所有 project 的后续执行。

## 6. 验收

- [ ] `schema.ex` 中 nap 默认 prompt 含 §3.1 全部要素(冗余错误处理/门控、依赖、死重、Linus & Carmack 逐条、产出格式)。
- [ ] `schema.ex` 中 day_dreaming 默认 prompt 含 §3.2 要素。
- [ ] `profiles.yml` 含 nap / day_dreaming 段,内容与代码默认值一致。
- [ ] 新建 instance workflow 的巡检 profile 默认值来自标准模板(测试覆盖)。
- [ ] import/export 包往返后 nap / day_dreaming 完整保留(测试覆盖)。
- [ ] `schema.ex` 中 nap 默认 prompt 含 2026-08-16 审计方法论全部要素（机械扫描前置、豁免 stale、无消费者 API、文档生成化、防复发门禁、产出格式含发现路径与验证方式、防误报纪律）。
- [ ] `mix specs.check` 通过。
- [ ] `scripts/check.sh`、`scripts/unit.sh` 与 `scripts/dialyzer.sh` 通过。

## 7. 后续衔接

巡检调度、结果去重、dashboard 按钮等留待后续工作。
