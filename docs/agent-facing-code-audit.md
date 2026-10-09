---
title: Agent-Facing Code Constitution Audit
genre: reference
domain: [governance, code-quality, agents]
status: current
language: zh-CN
owner: SymphonyElixir.AgentCodeCheck
updated: 2026-10-09
---

# 面向 Agent 的代码总纲审计

本审计由 [L3 设计](agent-facing-code-design.md)拥有，以
[L4 总纲](spec-agent-facing-code.md)和
[`config/agent_code_governance.yml`](../config/agent_code_governance.yml)为合同。表格恰好包含
35 个总纲单元；“部分满足”表示合同已落位但仍是 `record_only` 或缺少分组条款证据，不能用于
仓库级正向符合性声明。

SYM-146 修订了已完成的 SYM-140 审计：删除原第 15 项“常驻规则文件行数”，因为该数值未按
本仓标定且 D-02 只作人工评审取向；后续项目依次前移，总数由 36 改为 35。

| # | 单元 | 结果 | 可复跑证据 |
| ---: | --- | --- | --- |
| 01 | 约束：读取有截断 → L | 满足 | `docs/spec-agent-facing-code.md:22`; `mix agent_code.check` 检查 `file_lines` |
| 02 | 约束：注意力随上下文退化 → N | 满足 | `docs/spec-agent-facing-code.md:23`; `mix agent_code.check` 记录 `identifier_occurrences` |
| 03 | 约束：检索比整读便宜 → N、D | 满足 | `docs/spec-agent-facing-code.md:24`; `rg -n 'mix agent_code.check' README.md scripts/check.sh` |
| 04 | 约束：每次动作都计费 → V、O | 满足 | `docs/spec-agent-facing-code.md:25`; `scripts/quality.sh` 与 JSON 输出测试 |
| 05 | 阈值档：红线 | 满足 | `docs/spec-agent-facing-code.md:31`; checker 边界与退出码测试 |
| 06 | 阈值档：默认 | 满足 | `docs/spec-agent-facing-code.md:32`; checker 的 `justified` finding 测试 |
| 07 | 阈值档：建议 | 满足 | `docs/spec-agent-facing-code.md:33`; checker 的 `record_only` finding 测试 |
| 08 | 取证：机器可查 | 满足 | `docs/spec-agent-facing-code.md:40`; `scripts/check.sh` |
| 09 | 取证：人核 | 满足 | `docs/spec-agent-facing-code.md:41`; 抽样比例和记录位置是使用该档的必填合同 |
| 10 | 取证：只作取向 | 满足 | `docs/spec-agent-facing-code.md:42`; `record_only` 不进入结论 |
| 11 | 阈值：单文件行数 | 满足 | `mix agent_code.check`; 2000 行红线已接线，零水位没有基线放行分支 |
| 12 | 阈值：单函数行数 | 部分满足 | `mix agent_code.check --format json`; 确定性取证已实现，40/20 尚待分组标定，保持 `record_only` |
| 13 | 阈值：嵌套深度 | 部分满足 | `mix agent_code.check --format json`; 确定性取证已实现，4/2 尚待分组标定，保持 `record_only` |
| 14 | 阈值：同名标识符出现次数 | 部分满足 | `mix agent_code.check --format json`; 声明名口径已固定，框架 callback 校准未完成 |
| 15 | 阈值：全量门禁时长 | 部分满足 | `TIMEFORMAT='ELAPSED_SECONDS=%R'; time scripts/quality.sh` → `68.144` 秒；重复标定前保持 `record_only` |
| 16 | 阈值：单次变更规模 | 部分满足 | `git diff --numstat origin/main...HEAD` → `1176` 新增、`5` 删除、合计 `1181`；阈值待仓库标定 |
| 17 | 仓库实测覆盖规则 | 满足 | `config/agent_code_governance.yml`; 每项含 method/sample/sample_value/date/distribution，未标定项不得生效 |
| 18 | 等级：完全符合 | 满足 | `docs/spec-agent-facing-code.md:68`; 声明必须回链全部分组证据 |
| 19 | 等级：部分符合 | 满足 | `docs/spec-agent-facing-code.md:69`; 声明必须回链 G/N/V 及补齐计划 |
| 20 | 等级：起步阶段 | 满足 | `docs/spec-agent-facing-code.md:70`; 本票明确不作该正向声明 |
| 21 | 等级：不符合 | 满足 | `docs/spec-agent-facing-code.md:71`; 禁止无计划时声称面向 agent |
| 22 | 声明字段：实现名称与版本 | 满足 | `docs/spec-agent-facing-code.md:82` |
| 23 | 声明字段：声明日期与复核周期 | 满足 | `docs/spec-agent-facing-code.md:83` |
| 24 | 声明字段：符合性等级 | 满足 | `docs/spec-agent-facing-code.md:84` |
| 25 | 声明字段：未满足条款编号 | 满足 | `docs/spec-agent-facing-code.md:85` |
| 26 | 声明字段：偏离“应当”条款的编号与理由 | 满足 | `docs/spec-agent-facing-code.md:86` |
| 27 | 声明字段：阈值文件的覆盖日期 | 满足 | `docs/spec-agent-facing-code.md:87` |
| 28 | 声明字段：补齐计划与时间点 | 满足 | `docs/spec-agent-facing-code.md:88` |
| 29 | 声明字段：声明人 | 满足 | `docs/spec-agent-facing-code.md:89` |
| 30 | 稳定条款引用规则 | 满足 | `docs/spec-agent-facing-code.md:91`; 示例保留 V-01 |
| 31 | 来源：Clean Code for AI Agents 的三轴与四约束 | 满足 | `docs/spec-agent-facing-code.md:96` |
| 32 | 来源：同文的常驻规则形态与命令漂移 | 满足 | `docs/spec-agent-facing-code.md:99` |
| 33 | 来源：agent-rules-books 的分层对照 | 满足 | `docs/spec-agent-facing-code.md:101`; 不导出常驻规则数值门禁 |
| 34 | 来源：agent-style 的 enforcement 与严重度 | 满足 | `docs/spec-agent-facing-code.md:104` |
| 35 | 来源：agent-test-spec 的句式、等级与声明表 | 满足 | `docs/spec-agent-facing-code.md:106` |

上述表仍只说明原有 35 个总纲单元的落位与当前阈值状态，不改变其单元数量或含义。

## G-01 至 G-08 最终审计

| 条款 | 判定 | 可复跑证据 |
| --- | --- | --- |
| G-01 | 满足 | `mix agent_code.check list --format json`; `mix agent_code.check stats --format json`; stats 中 `handwritten + excluded = tracked`，check JSON 返回同一 scope 统计 |
| G-02 | 满足 | `config/agent_code_governance.yml`; 六个 threshold 均含本仓 calibration date/method/sample/sample_value/distribution，五项仍为 `record_only` |
| G-03 | 满足 | `config/agent_code_governance.yml`; 恰好 G-01 至 G-08，每项只有合法 `evidence_tier` 与非空 `evidence_method` |
| G-04 | 满足 | `mix agent_code.check` 输出 `baseline_remaining=0`; `test/symphony_elixir/agent_code_check_test.exs` 覆盖直接新增违规和旧/日期/偏好型基线数据失败 |
| G-05 | 满足 | `docs/spec-agent-facing-code.md` 的“RFC 2119 中文规范词”固定必须/不得、应当/不宜、可以语义 |
| G-06 | 满足 | `config/agent_code_governance.yml` 的 specification version/effective_on/change 与 `agent_code` gate 对应，严格 schema 测试覆盖不一致失败 |
| G-07 | 满足 | `README.md` 的 Refinement 与 Implementation 工作流继续保留人工 review 状态；本规范没有新增评审流程 |
| G-08 | 满足 | 登记表把唯一 enforced threshold `file_lines` 恰好映射到 `mix agent_code.check`，并验证 `scripts/check.sh` 包含该命令 |

G 组终态：8 条满足 / 0 条部分满足 / 0 条不满足 / 0 条不适用。仓库级九组 67 条仍须由各分组
证据独立完成，本表不据此作仓库级正向符合性声明。
