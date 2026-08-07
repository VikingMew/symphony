---
title: Workflow 页面设计目标
genre: design
domain: [settings, workflow]
status: current
design_status: proposed
language: zh-CN
updated: 2026-08-07
---

# Workflow 页面设计目标

本文维护 Settings 中 Workflow、Agents 和相关 Project 配置入口的长期目标状态。它关注 Web UI 如何编辑、验证、上传导入、导出和版本化完整 workflow package，同时明确哪些配置属于 project 记录而不是 workflow draft。

## 目标

`/settings/workflow` 不应主要表现为一个巨大的纯文本框。目标页面应该像普通配置页面一样，由多个表单区域、输入框、选择器、textarea、列表编辑器、预览和校验结果组成。

Settings 必须覆盖完整 runtime contract，而不是只覆盖 prompt。不同 tab 的责任边界如下：

- project 配置：属于 `/settings/projects`，包括每个 project 的 Linear project slug、repository URL、default branch、enabled 状态和描述。
- tracker 连接边界：Linear tracker kind 和默认 endpoint 是固定 runtime fact，不作为 workflow 表单里的可编辑字段。
- workflow tracker policy：属于 `/settings/workflow`，包括 assignee、active states、terminal states、human review states 和 allowed transitions。
- polling 配置
- workspace 配置
- hook 配置
- agent 配置
- codex 配置
- server / dashboard 配置
- workflow states、review states、allowed transitions
- execution profiles、base prompt、profile prompt policy、allowed updates；这些属于 `/settings/agents`

## 入口

Settings 长期应提供几个互相一致的 tab/入口：

- `/settings/projects` 项目设置：编辑多个 project。每个 project 拥有自己的 Linear project slug、repository URL、default branch、source strategy 和 enabled 状态；共享 Linear discovery 结果可辅助复制 project slug。workspace source 路径模型由 `docs/workspace_source_layout.zh-CN.md` 维护，repository base root 和 worktree base root 是共享 workspace/runtime 设置，不是 project-level 设置。
- `/settings/workflow` 结构化编辑：按 tracker、bootstrap、workspace、hooks、agent、codex、workflow routing 等区域编辑策略（通过 Settings 顶部 project 选择器限定到指定 project）。
- `/settings/agents` 结构化编辑：编辑 base prompt、profiles、profile prompt policy、allowed updates、executor policy。
- `/settings/runtime` 运行时摘要：展示 tracker/config 摘要和运行时相关配置。
- Split package 导入：`/settings/import` 可粘贴或上传 `workflow.yml` / `profiles.yml`，解析后进入同一套结构化模型，显示 staged diff 和校验结果。导入根据 YAML 字段自动识别 package 类型；确认导入只修改 editable draft，运行时只有正常 Save 后才变化。字段可解析时可以保存为新的 workflow version；语义校验失败时保存 configuration check failure，并阻止运行时监听。

这些入口必须写入同一个 workflow version 模型，避免 UI 配置、导入文件和导出的 Markdown 配置分裂。

## 页面结构

`/settings/workflow` 的目标状态是一个可逐步保存、可验证、可审计的配置工作台。页面应按配置域拆分，而不是要求用户直接编辑完整 YAML。

- Overview：显示 runtime source、active workflow version、最近保存/激活时间、是否有未保存变更、当前配置是否通过校验。
- Tracker：编辑 assignee、active states、terminal states。Linear project slug 在 `/settings/projects` 按 project 配置；tracker kind 和 endpoint 不在这里编辑。
- Bootstrap：编辑 initialize timeout、setup commands、cleanup commands。repository URL、default branch、checkout depth 和 source strategy 在 `/settings/projects` 按 project 配置；repository base root 和 worktree base root 在共享 Workspace/Runtime 设置中配置。
- Workspace：编辑 workspace root 和清理策略。
- Hooks：分别编辑 after_create、before_run、after_run、before_remove 和 timeout。
- Agent：编辑 max concurrent agents、max turns、retry/backoff、按 state 或 profile 的并发限制。
- Codex：编辑 pre-start commands、command、sandbox、approval policy、timeout、proxy/env allowlist。pre-start commands 用于 `source ~/.nvs/nvs.sh`、`nvs use 22`、PATH 修改等启动前环境准备，和 `codex.command` 在同一个 shell 中执行，不属于 lifecycle hooks。
- Workflow State Model：编辑 state -> profile 路由、human review states、allowed transitions。
- Agents：编辑共享 base prompt，并用重复表单编辑每个 profile 的 name、executor type、prompt mode、prompt template、allowed updates、target states、tool policy。
- Versions / Diff：展示版本历史、active 标记、保存来源、diff、回滚/激活按钮。
- Import / Export：支持导入 split workflow package，导出当前 active 或指定 version 为完整 split package。

## Verification

每个配置框都应该有自己的 verification，不只依赖最终保存时报一个大错误。

字段级 verification 至少分三层：

- Field validation：单个输入框的类型、空值、范围、格式，例如 timeout 必须是正整数。
- Section validation：同一区域内的交叉约束，例如 active states 和 terminal states 不应冲突。
- Contract validation：跨区域约束，例如 `workflow.states.Ready.profile` 引用的 profile 必须存在，profile allowed target states 必须符合 allowed transitions。

典型校验包括：

- Tracker：状态名称是否为空、active/terminal 是否冲突。
- Projects / Bootstrap：按 project 校验 Linear project slug、repository URL、default branch；共享 bootstrap 命令校验为空/危险命令、initialize timeout 必须为正整数、workspace 初始化是否可生成。
- Workspace：路径是否为空、是否落在允许范围、是否可展开 `~`。
- Hooks：每个 hook 单独显示 shell 风险提示、timeout 校验和可选 dry-run/preview。
- Agent：并发数、turn 数、retry/backoff 必须是正整数，状态/profile 引用必须存在。
- Codex：敏感 env 不泄漏、command 非空、sandbox policy 可解析，`approval_policy` 必须是 Codex app-server 支持的字符串枚举：`untrusted`、`on-failure`、`on-request`、`granular` 或 `never`。旧的结构化 `reject` map 不是公开配置，也不能再次被保存为 active workflow。
- Workflow State Model：目标 state 是否存在、profile 是否存在、human/codex actor 是否越权、review gate 是否可打回。
- Profiles：Codex profile 的 `extend/replace` 必须有 template，`disabled` 只能用于非 Codex executor，target states 必须被 workflow 允许。
- Prompt：按 profile 展示渲染后的 prompt，例如 refinement/implementation/merge 各自的 `extend` 或 `replace` 结果。

UI 行为上，字段失效时应在对应输入附近显示错误，同时页面顶部聚合当前阻塞保存的问题。保存按钮必须始终给出明确反馈：点击后显示 saving，成功显示 saved，失败显示 failed 和原因。

字段级错误和语义错误必须分开处理：

- Field validation 阻止保存的是无法可靠解析或持久化的字段值，例如必须为正整数却不是数字。
- Section / Contract validation 可以生成 configuration check failure，但不应阻止保存一个可解析的 draft；即使错误来自当前页面内的 transition/state/profile 组合，也只能提示和阻止运行时监听，不能阻止用户保存长表单进度。保存后运行时可以继续保持 setup-required 或 listening disabled，并在 Settings / Diagnostics 中说明缺哪个 project、workflow state、transition 或环境变量。
- Linear state existence 属于外部系统匹配问题。Settings 可以显示 discovery 对比结果和修复建议，但不应把“Linear 侧没有这个 state”伪装成输入框格式错误。

## Split Package 导入

导入文件必须先解析成同一套结构化 state，再显示字段级错误和 diff，不能绕过表单校验直接写入数据库。

导入流程：

1. 提供一个 YAML 文档。当前 UI 通过 `/settings/import` 粘贴或上传 `workflow.yml` / `profiles.yml`；两种输入使用同一 parser。
2. 解析 runtime/routing YAML、profiles YAML 和 `base_prompt`。
3. 映射到结构化 workflow form state。
4. 运行 field、section、contract 三层 verification，并区分“不能解析/不能保存”和“能保存但运行时不可用”。
5. 展示与当前 active workflow version 的 diff。
6. 字段可解析时保存为新的 workflow version；语义校验结果随版本一起展示为 configuration check。
7. 用户显式激活或保存即激活，取决于页面当前操作语义。

## 导出

页面应支持把当前 active workflow version 或指定历史 version 导出为完整 split package。导出的文件必须可以重新上传导入，并得到等价的 workflow version。

长期目标不提供原文查看或高级 raw editor 作为编辑入口。需要修改 workflow 时应通过结构化表单完成；需要迁移或备份时使用导出文件。

## 验收方向

后续实现应能验证：

- `/settings/workflow` 默认展示结构化配置页面，而不是只有 raw textarea。
- 修改单个字段会在该字段附近显示 field verification 结果。
- 跨字段错误会显示在对应 section 和页面顶部汇总里。
- 语义错误不会让保存按钮失效；保存后会刷新 configuration check，并明确说明下一步去 Projects、Workflow、Agents 还是环境变量修。
- 导入无效 split package 不会创建 workflow version。
- 导入有效 split package 会生成结构化表单 state、展示 diff，并能保存为 workflow version。
- 导入入口必须清楚标明导入只填充 draft，不等于保存或激活。当前实现允许粘贴或上传 `workflow.yml` / `profiles.yml` 内容，并自动识别类型；后续导入体验优化必须复用同一 parser、diff 和 draft flow。
- 页面不提供原文查看或高级 raw editor 编辑入口。
- 导出的 split package 可以重新上传导入并得到等价 workflow version。
