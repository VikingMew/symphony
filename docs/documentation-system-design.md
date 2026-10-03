---
title: Symphony 文档体系设计
genre: design
domain: [meta, documentation]
status: current
language: zh-CN
updated: 2026-10-03
design_status: landed
---

## 1. 背景与问题

迁移前,17 篇文档平铺在 `elixir/docs/` + 根级 SPEC/ARCHITECTURE/CODE_STRUCTURE,存在四个结构病(现已按本设计归位):

1. **无分类结构**:设计/规范/参考/指南/路线图 5 种体裁混在一个目录,找文档靠文件名记忆。
2. **语言双轨混乱**:规范用 EN、设计用 zh-CN,无成文规则;CODE_STRUCTURE 是唯一 EN+zh 双份,同步维护成本高。
3. **无权威分层**:SPEC(2184 行)与设计文档冲突时谁赢没有规则;`docs/documentation-alignment.md` 是历史补丁不是持续机制。
4. **无验证钩子**:文档漂移只能靠人工 grep。

## 2. 参考模型

采用 letsinflu-server 的 **L0-L5 分层模型**(物理平铺 + 概念分层 + 命名约定 + 布局检查脚本):

- **L0 Governance**:charter / decisions(ADR)
- **L1 System architecture**:只讲拓扑、信任/数据边界、跨切不变量、长期方向;禁止包级/功能级细节
- **L2 Backend design**:包布局与规则、HTTP/auth/storage/测试约定、功能设计索引;不写拓扑/方向叙事
- **L3 Feature designs**:`*-design.md` 一主题一篇,每篇 owner 自己的 contract
- **L4 Normative contracts**:参考表与线格式契约,无叙事
- **L5 Operational guides**:runbook,以"步骤能跑通"为判据

核心规则:**每个 contract 有且只有一个 owning 文档,其他文档链接不复制;新文档必须归入恰好一层。**

## 3. Symphony 层模型

当前形态(根级 `docs/`,无 `elixir/` 子目录):

| 层 | 文档 | 说明 |
|---|---|---|
| L0 | `AGENTS.md`(根)、`docs/README.md`、`docs/decisions.md`、`docs/documentation-alignment.md`、`docs/documentation-system-design.md` | 治理:贡献规则、决策日志(ADR)、一致性矩阵、本设计 |
| L1 | `docs/ARCHITECTURE.md`、`docs/long_term_direction.zh-CN.md` | 拓扑/边界/不变量/方向;收敛为系统级,不含包级细节 |
| L2 | `docs/design.md` | 包布局与约定 + **Feature Design Index**;原 CODE_STRUCTURE 已并入 |
| L3 | `docs/*-design.md` | worker-panel-decoupling-design、execution-runtime-design、workspace-source-layout-design、codex-linear-interaction-design、codex-linear-implementation-workflow-design、codex-linear-task-refinement-workflow-design、dashboard-color-system-design、hot-update-design 等；每篇标 `design_status: landed/partial/proposed` |
| L4 | `docs/spec.md`(总纲)+ `docs/spec-*.md`(8 个域契约)、`docs/logging.md`、`docs/token_accounting.md`、`docs/persistence_and_auth.md`、`docs/test_database_isolation.md` | SPEC 已按域拆分(§4 域模型、§5-6 工作流/配置、§7-9 编排、§10/12 Agent Runner、§11 Linear、§13 观测、§14-15 可靠性/安全、§16 参考算法、§17-18 一致性) |
| L5 | `docs/user-guide.zh-CN.md`、`docs/deployment.md` | 操作指南 |

## 4. 命名约定

- 功能设计:`<concern>-design.md`(一主题一篇)
- 规范契约:`<domain>-contract.md` 或固定名(`spec.md`、`logging.md`)
- 层锚固定名:`AGENTS.md`、`decisions.md`、`architecture.md`、`design.md`、`README.md`
- 指南:`<name>-guide.md` 或固定名(`deployment.md`、`user-guide.zh-CN.md`)
- **废除双份翻译**(CODE_STRUCTURE.zh-CN 模式):单份权威 + frontmatter `translation_of:` 链接

## 5. frontmatter 规范

每篇文档头部(由 `mix docs.check` 强制):

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
2. **`mix docs.check`**:校验每篇文档有 frontmatter、genre 合法、层归属合法、在索引注册、`owner` 代码锚点存在(对 reference 文档 grep 模块/函数)。
3. **单一事实源**:每个契约一个 owner 文档,其他文档链接不复制(219 的"共享配置"漂移即两处复制产物)。
4. **语言规则成文**:L1/L4 = EN(与代码一致);L3/L5 可 zh-CN 但声明 `language:`;禁止双份同步翻译。

## 7. 可扩展性

- 新功能 → Linear 完成任务定义与确认 → 一篇 `*-design.md`(L3)记录未来意图 → 入 `design.md` Feature Design Index → 落地后同步 L4 contract；PR 与 commit 保留实现评审和交付证据。
- 新领域(worker、webhooks…)只加 `domain` 标签与文档文件,不破坏层结构。
- genre 集合固定;新增 genre 需修订本文档(meta 宪法)。

## 8. 已完成的迁移

- **225 文档元体系**(✅ 已完成):层模型写入 AGENTS.md、`docs/README.md` 导航、`decisions.md` 建立、`mix docs.check` 工具。
- **226 elixir/ 提升为根**(✅ 已完成):代码移根、README 合并、Makefile/mise 从根跑、CI 路径更新。
- **227 文档物理归位**(✅ 已完成):全部文档进根 docs/、锚点去 elixir/ 前缀、SPEC 按域拆分、CODE_STRUCTURE 并入 design.md、语言规则落地、全量贴 frontmatter。

顺序逻辑:225 纯设计不依赖路径 → 226 动代码(锚点一次改对)→ 227 物理归位(不二次移动)。精确性机制在 225 就位,迁移全程有 `docs.check` 护航。

## 9. 漂移信号(docs-drift)

`mix docs.drift` 从 `docs/README.md` 的 L1/L4/L5 表格解析目标 Markdown 路径，
并始终纳入 `docs/documentation-alignment.md`；L3 功能设计不在扫描范围内。
索引是唯一 registry，不维护第二份文档清单。

`mix docs.check` 负责 frontmatter、genre/层合法性、索引注册和 owner anchor 存在性；
`mix docs.drift` 负责内容引用完整性与 Git 历史新鲜度。两者互补，互不替代。
引用扫描只读取行内代码，跳过 fenced code block、命令、flags、URL、状态、通配符和普通值：

- module：完整的 `SymphonyElixir.*` / `Mix.Tasks.*` 模块名必须精确匹配 `lib/` 内
  的 `defmodule` 声明，包括嵌套模块。
- path：`lib/`、`config/`、`docs/`、`.github/`、`test/`、`scripts/` 开头的具体路径，
  或明确的根文件名（如 `README.md`、`mix.exs`、`compose.yaml`）。只移除末尾行号或
  fragment 后检查存在性；无根目录的导入包文件名（如 `workflow.yml`）不推断为根路径。
- config：完整 `SYMPHONY_*` 名称，以及代码中 `System.get_env` / `System.fetch_env`
  明确读取的完整环境变量名；另检查完整 `SymphonyElixir.Config.*` 函数引用，支持
  裸函数名、`/arity` 和无参调用写法。标识符必须精确存在于 `lib/` 或 `config/`，
  函数也可通过完整模块内的公开声明解析，不接受更长名称的子串匹配。

`docs/drift-allowlist.yml` 顶层只有 `entries` 列表，每项恰好包含 `document`、`token`、
非空 `reason`。结构错误、重复 document/token 身份、已无当前候选的条目均报错。
豁免必须有可复核理由；当前基线仅豁免 Compose/Dockerfile 声明、测试目录模块与明确说明
已移除的历史变量，不能用豁免隐藏未知漂移。无效引用输出稳定的 `kind`、`document`、
`line`、`token`、`reason` 字段。

新鲜度只复用 frontmatter `owner`：完整模块解析到声明文件，仓库相对路径必须存在。
没有单一 owner 的治理矩阵明确输出带原因的 `SKIP`，不猜测归属。
使用 Git 最后触及文档及 owner 的提交时间（UTC committer timestamp），重命名计为一次修改，
支持跟随文件重命名；首次提交即可提供历史，代码/文档同提交的时间差为零。
只有 owner 晚于文档且差值严格大于阈值才是 `stale`；默认 30 天，
CLI 参数 `--freshness-days N` 可覆盖（非负整数），不引入运行时配置。
未提交的文件内容用于引用扫描，未提交的修改不改变 Git 时间；缺少 Git 历史或 owner 无效是显式错误。

人类输出和 `--format json` 共用新鲜度字段 `document`、`owner`、`doc_last_modified`、
`owner_last_touched`、`delta_days`、`status`、`reason`；不适用值为 JSON null。
JSON 顶层固定为 `references`、`freshness`、`allowlist_errors`、`summary`，供 SYM-27 消费。
引用状态为 `valid` / `exempt` / `error`，新鲜度状态为 `fresh` / `stale` / `SKIP` / `error`。
`summary` 包含 `documents`、`references`、`exempt`、`stale`、`skipped`、`errors` 计数。
`delta_days` 是 owner 时间减文档时间的秒数除以 86400，可为负值；不截断小数。

漂移告警信号为 **warning-only / non-blocking**：新鲜度 `stale` 永远不使命令失败。
`mix docs.drift` CLI 在无效引用、allowlist 错误、缺少 Git 历史、无效 owner 时非零退出，
用于暴露确定性输入错误，不把新鲜度启发式升级为合并门禁。

### PR change-linkage signal

独立的 `.github/workflows/docs-drift.yml` 在 PR opened、reopened、synchronize、edited、
ready_for_review 时运行 advisory linkage check。它以完整 Git 历史检查 PR base/head 的
三点 diff（`--diff-filter=ACDMRTUXB`），不调用 GitHub API；PR body 经环境变量写入临时文件。
本地接口为：

```bash
scripts/docs_drift_pr_linkage.sh --base <sha> --head <sha> [--body <path>]
```

- implementation paths：`lib/**`、`config/**`。
- documentation paths：`docs/**`、根目录 `README.md`、根目录 `AGENTS.md`。
- 其他路径均为 neutral（包括 `.github/**`、`scripts/**`、`test/**`、`mix.exs`），既不触发也不满足文档联动。

有 implementation 变更而无 documentation 变更时，脚本只输出 **一条** `::warning`，
在同一 annotation 中按路径排序完整列出所有触发文件，不截断、不拆分；退出码为 0。
同时修改实现和文档、仅文档、仅 neutral 或空 diff 时输出简短 notice，无 warning，退出码为 0。

PR body 可用以下精确语法豁免（该节在 PR body 中的位置由
[PR body contract](pull-request-body.md) 定义）：

```markdown
#### Docs Drift Exemption

Reason: Internal refactor with no documented behavior change.
```

heading 整行必须恰为 `#### Docs Drift Exemption`，无前后空格，恰好四个 `#`；
下一非空行必须以 `Reason: ` 开头并含非空白理由。空白行可跳过，但不跳过其他内容。
有效豁免输出携带理由的 `::notice`，无 warning，退出码为 0。
缺少或格式错误的豁免（包括错误 heading 层级、heading 尾随空格、缺少 Reason、空白理由、
backtick/tilde fenced code block 中的示例）不能抑制 warning。annotation 内容转义 `%` 和换行。

信号始终 **warning-only / non-blocking**；workflow 步骤设置 `continue-on-error: true`，
不作为合并门禁。缺少必填 flag、无法解析本地 commit、无 merge base 或无法读取/解析所需 body
是输入错误：stderr 给出明确说明，stdout 输出一条 `::error::`，退出码为 2；不静默成功。
此信号只检查路径联动，不判断文档内容是否充分，也不改变 `mix docs.drift` 的引用/新鲜度语义。

## 10. D 组元文档与注释合同

本文拥有 D-01 至 D-08 的仓库级合同：

| 条款 | 规则 | 执行边界 |
| --- | --- | --- |
| D-01 | 根 `AGENTS.md` 必须存在，常驻规则使用短、祈使、可执行的句子。 | 文件存在由机器检查；句式质量由人工评审。 |
| D-02 | 常驻规则保持简短，把细节移入按需文档。 | 只作取向；不设置行数阈值，不进入机器符合性判定。数值注册边界由 [agent-facing code owner](agent-facing-code-design.md)维护。 |
| D-03 | `AGENTS.md` 的 Quality Gates 只列 `scripts/check.sh`、`scripts/unit.sh`、`scripts/dialyzer.sh`；同名脚本存在且可执行，CI 分别运行相同命令。 | `mix docs.check` 全量硬阻断。 |
| D-04 | 根 `README.md` 保留 Project Layout、Quick Start 和 Development，并在后两节保留启动与开发入口命令。 | `mix docs.check` 全量硬阻断。 |
| D-05 | 注释只保留非显然意图、意外决策理由、外部协议假设、出处四类内容。 | 常驻规则、一次性审计与代码评审；不做 NLP 判断。 |
| D-06 | 不用注释复述代码，也不用注释弥补坏命名或坏结构。 | 常驻规则、一次性审计与代码评审。 |
| D-07 | 重构时保留仍有效注释，随代码更新过时注释，并记录本次每个注释修改或删除的理由。 | 常驻规则、一次性审计与代码评审。 |
| D-08 | 规则、owner、L4 合同、审计与实现必须在同仓互相链接。 | 文档 review 与 `mix docs.check` 的既有 owner-anchor 检查共同负责。 |

确定性检查实现在 [`Mix.Tasks.Docs.Check`](../lib/mix/tasks/docs.check.ex)，其 moduledoc 指回本文；
[`scripts/check.sh`](../scripts/check.sh)把它接入 fast-check 阻断链，聚焦回归位于
[`test/mix/tasks/docs_check_task_test.exs`](../test/mix/tasks/docs_check_task_test.exs)。D-02 的六规则
注册、摘除语义和实现链接由 [agent-facing code owner](agent-facing-code-design.md)维护，L4 数值合同
与修订后的 35 单元证据分别位于 [总纲](spec-agent-facing-code.md)和
[审计](agent-facing-code-audit.md)。

D-01、D-03、D-04 在 SYM-146 开工同步后的确定性水位均为零，因此终态直接使用一个硬门禁路径。
没有 baseline 文件、条件分支、flag、环境变量、日期或豁免入口。命令成功时恰好输出一行
`D baseline: 0 remaining`；任一新增违规直接失败，并报告条款、文件、目标、期望和实际值。

## 11. 一次性注释审计

审计范围恰为 `lib/**/*.ex`、`config/**/*.exs`、`scripts/**/*.sh`、`test/**/*.exs`。Elixir 候选
使用 `Code.string_to_quoted_with_comments/2` 读取真实语法注释；shell 候选使用
`rg -n '^\s*#' scripts --glob '*.sh'`。shebang、Credo 工具指令、Markdown fixture 以及字符串或
heredoc 内的伪注释不进入人工分类。复跑命令为：

```bash
mise exec -- elixir -e 'Path.wildcard("{lib,config,test}/**/*.{ex,exs}") |> Enum.each(fn path -> {:ok, _, comments} = Code.string_to_quoted_with_comments(File.read!(path), columns: true); Enum.each(comments, &IO.puts("#{path}:#{&1.line}:#{&1.text}")) end)'
rg -n '^\s*#' scripts --glob '*.sh'
```

最终保留 144 个真实行注释：100 个出处、25 个外部协议假设、10 个非显然意图、9 个意外决策
理由。四个允许类别均有实例，因此没有需要登记为 0 的类别；`config/**/*.exs` 的真实行注释为
0。另排除 9 个 shell shebang、2 个 Credo 工具指令，以及 parser 未返回的 fixture/string/heredoc
伪注释。

| 类别 | 逐条路径证据 |
| --- | --- |
| 非显然意图（10） | `lib/mix/tasks/docs_drift.ex:118`; `lib/symphony_elixir/agent_runner.ex:42`; `lib/symphony_elixir/analytics.ex:80`; `lib/symphony_elixir/orchestrator.ex:4099-4100`; `test/symphony_elixir/blocking_decision_test.exs:113`; `test/symphony_elixir/core_test.exs:1116-1117`; `test/symphony_elixir/docs_drift_pr_linkage_test.exs:146`; `scripts/docs_drift_pr_linkage.sh:76` |
| 意外决策理由（9） | `lib/symphony_elixir/agent_runner.ex:858-859`; `lib/symphony_elixir/orchestrator.ex:39`; `lib/symphony_elixir/workspace.ex:1043-1044`; `test/symphony_elixir/execution_worker_deployment_test.exs:241-244` |
| 外部协议假设（25） | `lib/mix/tasks/docs.check.ex:197-198`; `lib/symphony_elixir/redaction.ex:60-63,78,109-112`; `lib/symphony_elixir/specs_check.ex:106-109`; `lib/symphony_elixir/ssh.ex:70-72,92-93`; `lib/symphony_elixir/worker/executor.ex:539-540`; `test/symphony_elixir/redaction_test.exs:114`; `test/symphony_elixir/worker/command_test.exs:25`; `scripts/docs_drift_pr_linkage.sh:50` |
| 出处（100） | `test/mix/tasks/workspace_before_remove_test.exs:380`; `test/symphony_elixir/agent_runner_test.exs:380,900`; `test/symphony_elixir/codex/tool_request_handler_test.exs:120`; `test/symphony_elixir/config/project_commands_test.exs:21,36`; `test/symphony_elixir/config_multi_project_test.exs:58-59,97-98,123-124`; `test/symphony_elixir/core_test.exs:1350`; `test/symphony_elixir/dashboard_signal_test.exs:117,119,121`; `test/symphony_elixir/default_project_placeholder_test.exs:38-39,69`; `test/symphony_elixir/dynamic_tool_test.exs:231,443,450,564,571,633,681,730,815`; `test/symphony_elixir/event_presenter_test.exs:68,70`; `test/symphony_elixir/execution_worker_deployment_test.exs:97,132,134,138,159,161,164,177,179,181,183,194,220,269`; `test/symphony_elixir/extensions_test.exs:1176`; `test/symphony_elixir/github_pull_request_test.exs:289,307,375,636`; `test/symphony_elixir/implementation_handoff_test.exs:71,140`; `test/symphony_elixir/linear_diagnostics_probes_test.exs:127`; `test/symphony_elixir/linear_diagnostics_test.exs:352,491,698`; `test/symphony_elixir/linear_health_test.exs:50,73`; `test/symphony_elixir/live_e2e_test.exs:142,148,181,186,241,277,281,288,292,304,381,400,404,621,627,636,642,646,677,688,734,778`; `test/symphony_elixir/orchestrator_operator_tasks_test.exs:466`; `test/symphony_elixir/orchestrator_status_test.exs:2262`; `test/symphony_elixir/redaction_test.exs:67,69,71`; `test/symphony_elixir/ssh_test.exs:184`; `test/symphony_elixir/worker/executor_test.exs:478`; `test/symphony_elixir/workflow_settings_package_test.exs:182`; `test/symphony_elixir/workflow_store_multi_project_test.exs:129-130,165-166,189-190`; `test/symphony_elixir/workspace/source_preparation_test.exs:196,213`; `test/symphony_elixir/workspace_disk_guard_test.exs:34`; `test/symphony_elixir_web/admin/observability_presenter_test.exs:18`; `test/symphony_elixir_web/live/observability_fake_persistence_test.exs:306,388`; `test/symphony_elixir_web/proxy_and_health_test.exs:75` |

审计删除了 5 个复述性注释，未修改其他注释文本：

| 路径（删除前行号） | 理由 |
| --- | --- |
| `test/symphony_elixir/config_multi_project_test.exs:41` | 只复述紧随其后的 context-restoration assertion。 |
| `test/symphony_elixir/redaction_test.exs:91` | 只复述紧随其后的 JSON encoding assertion。 |
| `test/symphony_elixir/redaction_test.exs:109` | 只复述紧随其后的 invalid-byte preservation assertion。 |
| `test/symphony_elixir/redaction_test.exs:112` | 只复述紧随其后的 JSON encoding assertion。 |
| `test/symphony_elixir/redaction_test.exs:128` | 只复述紧随其后的 JSON encoding assertion。 |

## 12. 最终符合性

| 条款 | 最终判定 | 证据 |
| --- | --- | --- |
| D-01 | 满足 | `AGENTS.md:1,31-42`；`mix docs.check` 验证根文件存在，人工抽查确认原则已改为祈使规则。 |
| D-02 | 满足 | `AGENTS.md:84-91`; `config/agent_code_thresholds.yml` 恰有 6 项；`mix agent_code.check --format json` 输出 `rules=6` 且没有 `resident_rule_lines` 或 `AGENTS.md` finding。 |
| D-03 | 满足 | `AGENTS.md:84-95`; `lib/mix/tasks/docs.check.ex:61-106`; `stat -c '%A %n' scripts/check.sh scripts/unit.sh scripts/dialyzer.sh` 均为可执行；`.github/workflows/make-all.yml:34,60,87` 与三条命令一致。 |
| D-04 | 满足 | `README.md:28-64,120-160,320-352`; `lib/mix/tasks/docs.check.ex:108-135`; 聚焦测试覆盖结构、启动和开发入口缺失。 |
| D-05 | 满足 | `AGENTS.md:112-113` 与本设计第 11 节逐条审计；四类保留计数为 10/9/25/100。 |
| D-06 | 满足 | `AGENTS.md:114`; 第 11 节删除理由表；最终人工复核没有已知复述性注释或用注释弥补坏命名的命中项。 |
| D-07 | 满足 | `AGENTS.md:115-116`; 第 11 节记录本次全部 5 个删除及理由，其他仍有效注释保持不变。 |
| D-08 | 满足 | 本文第 10 节链接 checker、检查链、测试、L4 与审计；`Mix.Tasks.Docs.Check` moduledoc 指回本文；`SymphonyElixir.AgentCodeCheck` 与 D-02 证据指回 `docs/agent-facing-code-design.md`。 |

汇总：8 条满足，0 条不满足，0 条不适用；D 组基线水位 0。`mix docs.check` 成功输出
`D baseline: 0 remaining`，并与 `mix agent_code.check` 一同由 `scripts/check.sh:7-8`进入阻断链。
