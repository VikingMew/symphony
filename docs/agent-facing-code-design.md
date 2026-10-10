---
title: Agent-Facing Code Conformance Design
genre: design
domain: [governance, code-quality, agents]
status: current
language: zh-CN
updated: 2026-10-10
design_status: landed
---

# 面向 Agent 的代码符合性设计

## 1. 所有权与边界

本文是面向 Agent 的代码符合性、G 组通用条款与 X 组测试治理行为的 L3 owner。规范性定义、
G-01 至 G-08、阈值语义、取证分类、符合性等级、声明格式和来源映射由
[L4 总纲](spec-agent-facing-code.md)唯一拥有；当前结构化事实由
[`config/agent_code_governance.yml`](../config/agent_code_governance.yml)唯一拥有；当前偏差由
[35 单元与 G 组审计](agent-facing-code-audit.md)记录；X-01 至 X-05 的当前事实由
[X 组符合性记录](agent-facing-code-x-conformance.md)记录；N-01 至 N-09 的当前事实由
[N 组符合性记录](agent-facing-code-n-conformance.md)记录。其他文档只链接这些合同。

本设计拥有 G 组的闭集范围、逐条取证、规范版本/生效记录、硬阈值检查器映射、无日期棘轮
生命周期、水位、阈值注册、确定性取证、检查器输出和质量门禁接入。它还拥有 X 组登记、
测试层映射、checker 自测/定标记录和门槛棘轮，以及 N 组独立 checker、无日期基线和质量
门禁的机制接入。N 的九条当前事实只属于 N 组符合性记录。除这些机制、G-01 至 G-08 与
X-01 至 X-05 外，它不实现或审计 L/V/O/D/P/C 组条款，也不据此填写仓库级正向符合性等级。D 组规则与确定性检查由
[文档体系设计](documentation-system-design.md#10-d-组元文档与注释合同)拥有；本文只拥有 D-02
删除数值门禁后的阈值注册边界。

V-01 至 V-09 及初始化、runner 日志/JSON、默认测试确定性和禁外网守卫由
[仓库验证设计](repository-verification-design.md)唯一拥有。本文继续拥有检查器 JSON、阈值、
门禁接入地位与完整门禁时长的 `record_only` 标定；runner 只报告观测，不设时长红线。

## 2. 数据流

`mix agent_code.check` 只读取治理登记表。登记表必须恰好包含 G-01 至 G-08、六个现有阈值、
规范版本/生效/变更记录、全仓范围和门禁映射；顶层及所有嵌套对象出现未知字段、缺字段或
重复身份时立即失败。每条 G 条款必须有唯一合法 `evidence_tier` 和非空 `evidence_method`；
每项标定必须保留日期、方法、样本、样本值和结构化分布。

范围解析以排序后的 `git ls-files` 为全集。每个路径必须恰好命中一个手写源模式，或一个带
`generated`、`third_party`、`binary`、`data` 类别和非空理由的排除模式；无命中和多重命中都
带路径失败。`check`、`list` 和 `stats` 复用同一解析器。阈值测量再从该手写源列表按自身路径
范围筛选，没有第二套文件枚举或隐藏排除规则。

检查器按登记范围排序文件和结果。已生效阈值严格在观测值大于红线时失败；等于红线通过。
默认值超限生成带登记理由的非阻断记录，`record_only` 阈值只产生观测，不进入符合性结论。
每个已生效阈值必须恰好映射一次到存在的 checker；checker 命令必须出现在登记的
`scripts/check.sh` 快速链中。缺少、重复或未接线的映射使登记表无效。

常驻规则应保持简短，并把细节移入按需文档；这是 D-02 的人工评审取向，不是数值阈值，
不进入登记表、checker finding 或符合性结论。SYM-146 删除了未完成本仓标定却已
生效的 `resident_rule_lines` 规则及其 `AGENTS.md` 旧放行条目；实现位于
[`SymphonyElixir.AgentCodeCheck`](../lib/symphony_elixir/agent_code_check.ex)，终态证据见
[文档体系设计的 D 组符合性表](documentation-system-design.md#12-最终符合性)。

Elixir 源码以带 token metadata 的 AST 取证。函数行数从 `def`/`defp` 起始行算至对应
`end`；嵌套深度计算函数内 `case`、`cond`、`for`、`fn`、`if`、`receive`、`try`、
`unless` 和 `with` 的最大层数；同名标识符按模块末段名及 `def`/`defp` 声明名做全仓计数。
解析错误是显式检查错误。

## 3. 输出和门禁

默认 `check` 输出稳定摘要、恰好一行 `agent_code waterline` 和可定位失败；水位包含
`baseline_remaining` 与已生效 `file_lines` 红线相对当前最大值的 `file_lines_headroom`。
`list` 输出排序后的手写源清单，`stats` 输出跟踪/手写/排除计数、排除类别计数与手写源总行数。
三种模式都支持单一 JSON 对象；默认 check JSON 含相同水位与范围事实。重复运行输出稳定，
已生效红线失败、闭集错误或解析错误使 Mix task 非零退出。

`scripts/check.sh` 运行静态符合性检查，因此现有 CI 的 fast-check job 会实际执行它；现有
unit 与 dialyzer jobs 继续执行另外两项等价门禁。`scripts/quality.sh` 是文档化的全量本地
入口，依序覆盖三项主质量命令。全量时长在重复标定完成前保持 `record_only`，所以当前没有
可用于符合性结论的生效时长红线。

## 4. 标定与无日期棘轮

性质含“本规范设定”的数值只有完成本仓标定后才能切换为 `enforced`。标定记录必须写明方法、
样本、样本值和日期；门禁时长与变更规模的仓库样本可以覆盖总纲参考值。切换状态必须同时
更新注册表、审计与测试。

G-04 的存量基线若存在，只能保存 `clause`、`path`、`identifier` 和非空 `reason`，只能删除，
不能加入日期、未知字段、通配符或人读偏好放行。基线外违规立即失败；重复、不完整或不再
命中当前违规的条目失败。唯一翻硬判据是 `baseline_remaining=0`，归零时删除登记字段和读取/
匹配分支，只保留直接硬门禁。

SYM-143 合入后，原两条 `file_lines` 记录所指文件分别缩至 11 行和 6 行，在本变更开始前已经
不再是 2000 行红线违规。按上述 stale 规则，它们不能迁移为活动基线；本变更删除旧双文件，
从零水位直接采用硬门禁。该结果与 [代码局部性设计](code-locality-design.md)的“水位归零后删除
基线机制”术语一致，没有空基线字段、日期状态、自动添加入口或偏好型放行路径。

## 5. 验证契约

- checker 单元测试覆盖严格解析、闭集分类、三档取证、版本/标定/门禁映射、边界值、
  基线数据拒绝、直接新增违规和稳定排序；
- Mix task 测试覆盖 check/list/stats 的人类与纯 JSON 输出、水位和退出码；
- 静态 CI 断言证明 workflow 仍调用 check/unit/dialyzer 三项等价门禁；
- 文档、public spec 和三项仓库质量门禁必须全部通过；
- 验证只使用本地 Elixir、脚本与 CI 静态读取，不调用容器引擎。

## 6. X 组测试治理

代码符合性与测试符合性是两项独立结论，任一方通过都不能推出另一方通过。X 组当前事实记录
恰好包含 X-01 至 X-05 五行；每行必须写基线状态、最终状态、精确证据、执行方式、执行种类和
单个测试层。未满足或部分满足必须填写补齐计划，不适用必须填写理由，空白处置不能完成审计。

本设计只拥有最小测试层接缝：机器可查项属于第 1/2 层，运行时行为属于第 3/4 层；标为阈值
的条款必须填写 1、2、3、4 中的一个层。它不扩写仓库外测试分层规范。

checker 边界是对仓库内容产生 pass/fail/advisory 质量判断的自有 Mix task 或扫描脚本。命令
串联脚本不重复计数，formatter、Credo、Dialyzer 和编译器的自身测试归上游。每个在界 checker
均为第 1 层，必须登记可定位聚焦测试，并以人工标注的 finding/预期输出为样本点记录不一致数、
样本数和两者之比。

`mix agent_code_x.check` 严格校验五条款集合、测试层映射、checker 集合与自测路径、定标算术、
X-04 棘轮字段、最终状态计数和 X-05 处置字段。错误定位到条款或 checker 与字段；首行输出稳定
水位并包含 `baseline_remaining`。本地 `mix lint` 与 CI 通过同一 alias 采用相同硬门禁语义。

门槛收紧先在尚未接入 `mix lint` 时运行检查器并记录精确初始 finding、人工样本、误报数和
误报率。接线后，基线外违规立即失败，存量只在活动基线期报告且基线只减不增。唯一翻硬判据
是 `baseline_remaining=0`；归零时删除活动基线及其放行逻辑，只保留一个硬门禁路径。生命周期
不使用日期截止、自动过期、豁免路径或 warning/hard 双模式。

## 7. N 组导航门禁

`mix agent_code_n.check` 独立扫描 N-01、N-03、N-05、N-06、N-07、N-08 与 N-09；N-02、
N-04 和 N-06 的语义部分保留为 `AGENTS.md` 的短人核规则。独立入口避免把 N 的无日期存量
基线混入 G 组治理登记表。`mix lint` 接线一次，`scripts/check.sh` 只经
该 alias 到达它；N-09 只验证模块地图与检索入口存在，引用完整性和新鲜度仍由既有
`mix docs.drift` 判定。

质量入口在执行 checker 或调用它的测试前运行 `scripts/prepare_navigation_git_history.sh`。
该脚本只在 Git checkout 为 shallow 时补全历史，并要求 `origin/main` 存在，使本地与 CI 都以
真实 merge base 执行同一棘轮比较；Git 历史不可用时门禁直接失败。

`mix agent_code_n.check --write-baseline` 复用同一扫描器、真实 merge base 与
`BaselineLocations` 映射，先在内存生成排序候选并完成形状、精确匹配和单调校验，全部通过后
才替换文件。该命令只用于已证明的位置迁移或删除存量，不得登记新 identity；失败时目标文件
字节不变，连续第二次执行是字节级 no-op。普通 check 使用同一 merge-base 上界，因此手工把
新 finding 写进当前分支 baseline 也不能绕过门禁。

检查器从带 token metadata 的 Elixir AST 取得模块、函数、类型、测试辅助和文件主模块位置，
按规则、声明类别、规范化名字与排序后的精确位置组成 finding identity。结果与 identity 均排序；
human 输出只有一行 `navigation baseline remaining: <整数>` 水位，JSON 返回同一整数。

[`config/agent_code_navigation_baseline.yml`](../config/agent_code_navigation_baseline.yml)只保存当前
仍存在的精确 identity，不含 owner、reason、日期或通配符。merge base 尚无文件时，首次集合
必须等于当前扫描集合；其后当前集合必须是经 Git 位置映射后的 merge-base 集合的子集。
位置映射调整同一路径中未被 diff 改写的声明行；跨文件职责移动只有在规范化声明头（含函数
arity）的当前多重集不超过 merge-base 多重集时才映射。插入或删除前文引起的行号移动不增加
水位。当前 YAML 仍须写出扫描所得的精确新位置，不能省略位置或按名称归并。声明头被改写、
无法取得 Git diff 均不能按纯位置移动放行。基线外 finding、聚合 finding
新增位置、基线新增和陈旧记录均失败，修复 finding 必须同次删除记录。水位是剩余记录数且只减
不增；归零时删除基线文件和 checker 的读取/比较分支，只保留直接硬门禁。此生命周期没有日期、
自动放行、兼容分支或 warning/hard 双模式。
