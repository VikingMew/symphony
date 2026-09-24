---
title: Agent-Facing Code Constitution Audit
genre: reference
domain: [governance, code-quality, agents]
status: current
language: zh-CN
owner: SymphonyElixir.AgentCodeCheck
updated: 2026-09-24
---

# 面向 Agent 的代码总纲审计

本审计由 [L3 设计](agent-facing-code-design.md)拥有，以
[L4 总纲](spec-agent-facing-code.md)和
[`config/agent_code_thresholds.yml`](../config/agent_code_thresholds.yml)为合同。表格恰好包含
36 个总纲单元；“部分满足”表示合同已落位但仍是 `record_only` 或缺少分组条款证据，不能用于
仓库级正向符合性声明。

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
| 11 | 阈值：单文件行数 | 满足 | `wc -l lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_status_test.exs` → `4239`, `2221`; 精确豁免截至 2026-12-31 |
| 12 | 阈值：单函数行数 | 部分满足 | `mix agent_code.check --format json`; 确定性取证已实现，40/20 尚待分组标定，保持 `record_only` |
| 13 | 阈值：嵌套深度 | 部分满足 | `mix agent_code.check --format json`; 确定性取证已实现，4/2 尚待分组标定，保持 `record_only` |
| 14 | 阈值：同名标识符出现次数 | 部分满足 | `mix agent_code.check --format json`; 声明名口径已固定，框架 callback 校准未完成 |
| 15 | 阈值：常驻规则文件行数 | 满足 | `wc -l AGENTS.md` → `146`; 本次新增 `0`; 精确豁免截至 2026-12-31 |
| 16 | 阈值：全量门禁时长 | 部分满足 | `TIMEFORMAT='ELAPSED_SECONDS=%R'; time scripts/quality.sh` → `68.144` 秒；重复标定前保持 `record_only` |
| 17 | 阈值：单次变更规模 | 部分满足 | `git diff --numstat origin/main...HEAD` → `1176` 新增、`5` 删除、合计 `1181`；阈值待仓库标定 |
| 18 | 仓库实测覆盖规则 | 满足 | `config/agent_code_thresholds.yml`; 每项含 method/sample/sample_value/date，未标定项不得生效 |
| 19 | 等级：完全符合 | 满足 | `docs/spec-agent-facing-code.md:66`; 声明必须回链全部分组证据 |
| 20 | 等级：部分符合 | 满足 | `docs/spec-agent-facing-code.md:67`; 声明必须回链 G/N/V 及补齐计划 |
| 21 | 等级：起步阶段 | 满足 | `docs/spec-agent-facing-code.md:68`; 本票明确不作该正向声明 |
| 22 | 等级：不符合 | 满足 | `docs/spec-agent-facing-code.md:69`; 禁止无计划时声称面向 agent |
| 23 | 声明字段：实现名称与版本 | 满足 | `docs/spec-agent-facing-code.md:80` |
| 24 | 声明字段：声明日期与复核周期 | 满足 | `docs/spec-agent-facing-code.md:81` |
| 25 | 声明字段：符合性等级 | 满足 | `docs/spec-agent-facing-code.md:82` |
| 26 | 声明字段：未满足条款编号 | 满足 | `docs/spec-agent-facing-code.md:83` |
| 27 | 声明字段：偏离“应当”条款的编号与理由 | 满足 | `docs/spec-agent-facing-code.md:84` |
| 28 | 声明字段：阈值文件的覆盖日期 | 满足 | `docs/spec-agent-facing-code.md:85` |
| 29 | 声明字段：补齐计划与时间点 | 满足 | `docs/spec-agent-facing-code.md:86` |
| 30 | 声明字段：声明人 | 满足 | `docs/spec-agent-facing-code.md:87` |
| 31 | 稳定条款引用规则 | 满足 | `docs/spec-agent-facing-code.md:89`; 示例保留 V-01 |
| 32 | 来源：Clean Code for AI Agents 的三轴与四约束 | 满足 | `docs/spec-agent-facing-code.md:94` |
| 33 | 来源：同文的常驻规则形态与命令漂移 | 满足 | `docs/spec-agent-facing-code.md:97` |
| 34 | 来源：agent-rules-books 的档位与行数对照 | 满足 | `docs/spec-agent-facing-code.md:99` |
| 35 | 来源：agent-style 的 enforcement 与严重度 | 满足 | `docs/spec-agent-facing-code.md:101` |
| 36 | 来源：agent-test-spec 的句式、等级与声明表 | 满足 | `docs/spec-agent-facing-code.md:103` |

本审计只说明 36 个总纲单元的落位与当前阈值状态，不表示九组 67 条已经完成。
