---
title: Agent-Facing Code Conformance Design
genre: design
domain: [governance, code-quality, agents]
status: current
language: zh-CN
updated: 2026-09-24
design_status: landed
---

# 面向 Agent 的代码符合性设计

## 1. 所有权与边界

本文是面向 Agent 的代码符合性行为的 L3 owner。规范性定义、阈值语义、取证分类、
符合性等级、声明格式和来源映射由
[L4 总纲](spec-agent-facing-code.md)唯一拥有；结构化数值由
[`config/agent_code_thresholds.yml`](../config/agent_code_thresholds.yml)拥有；当前偏差由
[36 单元审计](agent-facing-code-audit.md)记录。其他文档只链接这些合同。

本设计拥有阈值注册、确定性取证、精确豁免、检查器输出和质量门禁接入。它不实现或审计
G/N/L/V/O/D/P/C/X 九组的 67 条编号条款，也不据此填写仓库级正向符合性等级。

## 2. 数据流

`mix agent_code.check` 严格读取阈值注册表与豁免表。注册表必须恰好包含七个数值项；顶层、
规则、范围、排除和标定对象出现未知字段时立即失败。每个排除项都必须在注册表中给出路径
和理由，检查器没有隐藏排除规则。

检查器按注册表范围排序文件和结果。已生效规则严格在观测值大于红线时失败；等于红线
通过。红线只能由同时精确匹配规则与目标、并包含责任人、理由和到期日的豁免解除；过期或
不再命中当前目标的豁免失败。默认值超限生成带注册理由的非阻断记录。`record_only` 规则仅
产生观测，不进入符合性结论。

Elixir 源码以带 token metadata 的 AST 取证。函数行数从 `def`/`defp` 起始行算至对应
`end`；嵌套深度计算函数内 `case`、`cond`、`for`、`fn`、`if`、`receive`、`try`、
`unless` 和 `with` 的最大层数；同名标识符按模块末段名及 `def`/`defp` 声明名做全仓计数。
解析错误是显式检查错误。

## 3. 输出和门禁

默认输出只给出稳定摘要与可定位失败。`--format json` 输出单一 JSON 对象，字段和 findings
排序稳定。存在已生效红线失败、过期/陈旧豁免或解析错误时，Mix task 非零退出。

`scripts/check.sh` 运行静态符合性检查，因此现有 CI 的 fast-check job 会实际执行它；现有
unit 与 dialyzer jobs 继续执行另外两项等价门禁。`scripts/quality.sh` 是文档化的全量本地
入口，依序覆盖三项主质量命令。全量时长在重复标定完成前保持 `record_only`，所以当前没有
可用于符合性结论的生效时长红线。

## 4. 标定与豁免

性质含“本规范设定”的数值只有完成本仓标定后才能切换为 `enforced`。标定记录必须写明方法、
样本、样本值和日期；门禁时长与变更规模的仓库样本可以覆盖总纲参考值。切换状态必须同时
更新注册表、审计与测试。

豁免位于 [`config/agent_code_exemptions.yml`](../config/agent_code_exemptions.yml)。豁免不是
历史基线的静默放行：每条记录都在检查时验证当前精确目标和日期，到期后自动成为失败。

## 5. 验证契约

- checker 单元测试覆盖严格解析、边界值、路径范围、排除、过期/陈旧豁免和稳定排序；
- Mix task 测试覆盖人类输出、纯 JSON 输出和退出码；
- 静态 CI 断言证明 workflow 仍调用 check/unit/dialyzer 三项等价门禁；
- 文档、public spec 和三项仓库质量门禁必须全部通过；
- 验证只使用本地 Elixir、脚本与 CI 静态读取，不调用容器引擎。
