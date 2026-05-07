# Workflow 页面设计目标

本文维护 `/workflows` 页面的长期目标状态。它关注 Web UI 如何编辑、验证、上传导入、导出和版本化完整 workflow package。

## 目标

`/workflows` 不应主要表现为一个巨大的纯文本框。目标页面应该像普通配置页面一样，由多个表单区域、输入框、选择器、textarea、列表编辑器、预览和校验结果组成。

页面必须覆盖完整 `WORKFLOW.md` contract，而不是只覆盖 prompt：

- project 配置
- tracker 配置
- polling 配置
- workspace 配置
- hook 配置
- agent 配置
- codex 配置
- server / dashboard 配置
- workflow states、review states、allowed transitions
- execution profiles、profile prompt policy、allowed updates
- `WORKFLOW.md` body/base prompt

## 入口

Workflow 页面长期应提供两个互相一致的入口：

- 结构化编辑：默认入口。按 tracker、project/bootstrap、workspace、hooks、agent、codex、workflow、profiles、prompt 等区域编辑。
- 文件上传导入：上传一个完整 `WORKFLOW.md`，解析后进入同一套结构化模型，显示 diff 和校验结果，通过后才能保存为新的 workflow version。

这些入口必须写入同一个 workflow version 模型，避免 UI 配置、导入文件和导出的 Markdown 配置分裂。

## 页面结构

`/workflows` 的目标状态是一个可逐步保存、可验证、可审计的配置工作台。页面应按配置域拆分，而不是要求用户直接编辑完整 YAML。

- Overview：显示 runtime source、active workflow version、最近保存/激活时间、是否有未保存变更、当前配置是否通过校验。
- Tracker：编辑 tracker kind、endpoint、project slug、assignee、active states、terminal states。
- Project / Bootstrap：编辑 repository URL、default branch、checkout depth、setup commands、cleanup commands。
- Workspace：编辑 workspace root 和清理策略。
- Hooks：分别编辑 after_create、before_run、after_run、before_remove 和 timeout。
- Agent：编辑 max concurrent agents、max turns、retry/backoff、按 state 或 profile 的并发限制。
- Codex：编辑 command、sandbox、approval policy、timeout、proxy/env allowlist。
- Workflow State Model：编辑 state -> profile 路由、human review states、allowed transitions。
- Profiles：用重复表单编辑每个 profile 的 name、executor type、prompt mode、prompt template、allowed updates、target states、tool policy。
- Prompt：编辑 `WORKFLOW.md` body/base prompt，并预览最终 prompt 组合。
- Versions / Diff：展示版本历史、active 标记、保存来源、diff、回滚/激活按钮。
- Import / Export：支持上传导入完整 `WORKFLOW.md`，导出当前 active 或指定 version 为完整 `WORKFLOW.md`。

## Verification

每个配置框都应该有自己的 verification，不只依赖最终保存时报一个大错误。

字段级 verification 至少分三层：

- Field validation：单个输入框的类型、空值、范围、格式，例如 timeout 必须是正整数。
- Section validation：同一区域内的交叉约束，例如 active states 和 terminal states 不应冲突。
- Contract validation：跨区域约束，例如 `workflow.states.Ready.profile` 引用的 profile 必须存在，profile allowed target states 必须符合 allowed transitions。

典型校验包括：

- Tracker：endpoint 格式、必填 project slug、状态名称是否为空、active/terminal 是否冲突。
- Project / Bootstrap：repository URL、命令为空/危险命令、workspace 初始化是否可生成。
- Workspace：路径是否为空、是否落在允许范围、是否可展开 `~`。
- Hooks：每个 hook 单独显示 shell 风险提示、timeout 校验和可选 dry-run/preview。
- Agent：并发数、turn 数、retry/backoff 必须是正整数，状态/profile 引用必须存在。
- Codex：敏感 env 不泄漏、command 非空、sandbox policy 可解析。
- Workflow State Model：目标 state 是否存在、profile 是否存在、human/codex actor 是否越权、review gate 是否可打回。
- Profiles：Codex profile 的 `extend/replace` 必须有 template，`disabled` 只能用于非 Codex executor，target states 必须被 workflow 允许。
- Prompt：按 profile 展示渲染后的 prompt，例如 refinement/implementation/merge 各自的 `extend` 或 `replace` 结果。

UI 行为上，字段失效时应在对应输入附近显示错误，同时页面顶部聚合当前阻塞保存的问题。保存按钮只能在完整 contract validation 通过时创建新的 workflow version。

## WORKFLOW.md 上传导入

导入文件必须先解析成同一套结构化 state，再显示字段级错误和 diff，不能绕过表单校验直接写入数据库。

导入流程：

1. 上传完整 `WORKFLOW.md` 文件。
2. 解析 YAML front matter 和 Markdown body。
3. 映射到结构化 workflow form state。
4. 运行 field、section、contract 三层 verification。
5. 展示与当前 active workflow version 的 diff。
6. 通过校验后保存为新的 workflow version。
7. 用户显式激活或保存即激活，取决于页面当前操作语义。

## 导出

页面应支持把当前 active workflow version 或指定历史 version 导出为完整 `WORKFLOW.md`。导出的文件必须可以重新上传导入，并得到等价的 workflow version。

长期目标不提供原文查看或高级 raw editor 作为编辑入口。需要修改 workflow 时应通过结构化表单完成；需要迁移或备份时使用导出文件。

## 验收方向

后续实现应能验证：

- `/workflows` 默认展示结构化配置页面，而不是只有 raw textarea。
- 修改单个字段会在该字段附近显示 verification 结果。
- 跨字段错误会显示在对应 section 和页面顶部汇总里。
- 导入无效 `WORKFLOW.md` 不会创建 workflow version。
- 导入有效 `WORKFLOW.md` 会生成结构化表单 state、展示 diff，并能保存为 workflow version。
- 导入入口只接受上传文件，不提供粘贴原文。
- 页面不提供原文查看或高级 raw editor 编辑入口。
- 导出的 `WORKFLOW.md` 可以重新上传导入并得到等价 workflow version。
