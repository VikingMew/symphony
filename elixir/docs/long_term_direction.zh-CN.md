# Symphony 长期开发方向与技术选型

本文档记录 Symphony Elixir 参考实现的长期开发方向、技术选型和阶段性演进计划。目标是在安全性、性能、开发成本、调试成本之间取得平衡，同时让 Symphony 从当前的实验性编排服务演进为可长期运行、可观测、可配置的 Web 服务。

## 1. 总体方向

Symphony 后续应继续定位为一个长期运行的 Web 服务，而不是一次性 CLI 脚本。核心形态如下：

```text
Elixir / Phoenix Web Service
├── Web UI / Dashboard
├── JSON API
├── SQLite 持久化
├── Workflow / Project 配置管理
├── Orchestrator
├── Agent Run 管理
└── Worker Runtime / Sandbox Runtime
```

当前实现已经引入 SQLite、workflow version、dashboard 管理页面、Linear 诊断和 Panel 侧 worker API。
长期方向是让 DB 成为唯一运行时 workflow source，让 Web UI 成为主要配置入口。

一个关键原则是：runtime workflow contract 的全部内容都应该可配置并入库。这里的“全部”包括 tracker、polling、workspace、hooks、agent、codex、server 等运行配置，以及 base prompt 和 agent profile。Web UI 最终应该能够编辑、校验、版本化和审计整个 workflow contract，而不是只编辑其中一部分。`workflow.yml` 和 `profiles.yml` 可以作为导入/导出的交换格式，但不应再作为运行时配置来源。

另一个关键原则是：当前仍处于 alpha 阶段，开发时不保留历史兼容路径。产品方向变化后，应直接删除旧 route、旧 source label、旧 schema alias、旧文件 fallback、旧 fixture 和旧测试断言；除非某个 execplan 明确把一次性数据迁移列为交付物，否则不要为了过去的配置格式在 runtime、UI 或测试里保留隐藏兼容层。测试应该固定当前公开契约，而不是证明旧行为仍然可用。

### 1.1 文档状态标注约定

本文同时记录当前实现、阶段目标和长期方向。为了避免长期目标被误读为已经完成，后续维护时必须显式标注当前代码是否对齐：

- `已落地`：代码已经支持，文档可以按现状描述。
- `部分落地`：代码支持核心路径，但还缺 UI、验证、审计、异常路径或生产化细节。
- `阶段未到`：这是明确的后续目标，当前代码不支持是预期状态。
- `文档偏差`：文档把未实现能力写成了现状，或者字段/行为名称与代码不一致，需要修正文档或补实现。

如果发现文档和代码不一致，先判断它属于“阶段未到”还是“文档偏差”。阶段未到的内容应移动到路线图、目标状态或验收方向；文档偏差应直接改为当前真实行为，并保留后续目标。

当前已知对齐说明：

- `已落地`：SQLite workflow version、Settings tabbed configuration、结构化 `/settings/workflow` draft form、`/settings/agents` base prompt/profile 编辑、版本保存/激活、profile-aware prompt、restricted Linear task tools、project bootstrap schema、缺失 `project.repository_url` 阻止调度、每次 run 使用新 workspace、Codex session 启动后由 Symphony 执行 `Ready -> In Progress`。
- `阶段未到`：运行时完全 DB-only。目标状态下 Orchestrator、diagnostics、Settings 和 agent runner 都只读取 DB active workflow version；本地 split package 文件只作为导入/导出格式存在。空 DB 不自动 seed 文件，直接进入 setup-required，且不会开始监听或调度。
- `部分落地`：Workflow 页面已经不是纯 raw textarea，但仍未覆盖完整字段级 verification、diff 审计和页面级导出按钮；allowed transitions 目前主要以只读结构展示，不是完整编辑器。
- `部分落地`：`profiles.<id>.executor.type` schema 支持 `codex_agent`、`manual`、`backend_action`、`external_worker`，调度层当前只自动执行 `codex_agent` 状态；manual/backend/external 是路由契约和后续执行器扩展点。
- `部分落地`：Panel / Worker 数据模型、API、lease、heartbeat 和 dashboard 控制已存在，但生产 worker runtime、Docker worker 和更强 sandbox runner 仍是后续阶段。
- `阶段未到`：完整多项目生产路径、每项目独立 tracker/workflow 运行隔离、run detail/issue detail/events/logs 完整页面、secrets metadata 生产化管理、hook 审计事件、完整结构化 workflow diff。
- `文档偏差检查点`：凡是写成“当前已经”或“已支持”的句子，必须能在代码或测试中找到对应实现；否则应改成“目标”、“后续”或“部分落地”。

## 2. 技术选型结论

建议主系统继续使用：

```text
Elixir + OTP + Phoenix LiveView + Ecto + SQLite
```

不建议当前阶段整体重写为 Rust 或纯 Erlang。

Rust 可以作为后续局部组件选项，尤其适合实现高隔离、低权限、可单独分发的 worker runtime 或 sandbox runner。纯 Erlang 可以保留 BEAM/OTP 优势，但对 Web UI、配置表单、数据库开发、模板和日常维护来说，收益不如继续使用 Elixir/Phoenix。

## 3. 为什么继续使用 Elixir/Phoenix

Symphony 的主要工作负载是：

- 轮询 Linear 或其他 tracker。
- 管理 issue/run/workspace 状态。
- 启动和监督 Codex app-server 子进程。
- 维护重试、停止、清理等长期任务生命周期。
- 提供 dashboard、配置 UI 和 JSON API。
- 写入运行事件、日志索引和历史记录。

这些任务主要是 I/O、进程编排和状态管理，不是 CPU 密集型计算。Elixir/OTP 在长期运行、进程监督、失败恢复、消息传递和可观测性方面非常合适。Phoenix LiveView 可以在不引入独立前端项目的情况下构建实时 dashboard 和配置界面。

## 4. 不引入独立 Node 前端项目

长期 Web UI 默认使用 Phoenix LiveView，不引入 React、Vue、Next.js 等独立 Node 前端项目。

推荐 UI 栈：

```text
Phoenix LiveView
HEEx Components
Ecto Forms / Changesets
普通 CSS 或轻量 CSS 架构
少量 LiveView JS Hooks
```

这样可以保持一个 Elixir 应用同时负责：

- 后端编排。
- Web UI。
- 实时状态更新。
- JSON API。
- SQLite 持久化。
- 运维和调试入口。

如果后续需要构建工具，可以使用 Phoenix 自带的轻量 assets 流程，但不要演进成独立前端仓库或复杂 SPA，除非出现明确的产品需求。

## 5. SQLite 持久化方向

当前实现已经使用 Ecto + SQLite 保存项目、workflow versions、issues、runs、agent turns、
workspaces、events、workers、worker sessions、tasks 和 leases。内存状态仍负责当前
orchestrator loop 的即时调度视图，但 dashboard 和历史记录已经依赖 SQLite。

后续重点不再是“是否引入 SQLite”，而是继续完善 schema 边界、迁移策略、恢复语义和 UI
编辑能力。未来如果需要多用户、多实例或更高并发，可以通过 Ecto 迁移到 Postgres。

当前或目标核心表包括：

```text
projects
tracker_configs
workflow_versions
issues
runs
agent_turns
workspaces
events
workers
worker_sessions
tasks
task_leases
secrets_metadata（后续）
```

### 5.1 projects

保存 Symphony 管理的项目。

典型字段：

- `id`
- `name`
- `slug`
- `description`
- `enabled`
- `created_at`
- `updated_at`

### 5.2 tracker_configs

保存 Linear 等 tracker 的连接和筛选配置。

典型字段：

- `id`
- `project_id`
- `kind`
- `project_slug`
- `active_states`
- `terminal_states`
- `api_key_secret_ref`
- `created_at`
- `updated_at`

### 5.3 workflow_versions

保存完整 workflow package 的运行时版本。Web UI 会按 settings 页面做历史过滤：
Workflow 页面显示 workflow 设置保存，Agents 页面显示 profile/prompt 保存。
从页面历史恢复时只恢复该页面负责的字段，并写入一个新的完整 active workflow version，
而不是直接激活旧版本覆盖其它页面负责的字段。

典型字段：

- `id`
- `project_id`
- `version`
- `yaml_config`
- `prompt_body`
- `raw_workflow_md`
- `source`
- `active`
- `created_at`

每次 agent run 应绑定当时使用的 workflow version，方便后续 debug 和审计。

`raw_workflow_md` 用于保留完整原文，`yaml_config` 和 `prompt_body` 用于结构化读取和 UI 展示。这样可以同时满足机器校验、表单编辑、diff 审计和无损导入/导出。

### 5.4 runs / agent_turns / events

保存执行历史和运行事件。

```text
runs
├── issue_identifier
├── workflow_version_id
├── workspace_path
├── status
├── attempt
├── started_at
├── finished_at
└── failure_reason

agent_turns
├── run_id
├── turn_index
├── status
├── started_at
├── finished_at
└── summary

events
├── project_id
├── run_id
├── issue_identifier
├── event_type
├── payload_json
└── inserted_at
```

## 6. 配置管理演进

配置管理建议分阶段推进，但运行时真相以 SQLite workflow version 为准。split package 只作为导入/导出格式。

### 阶段 1：运行状态持久化与 DB workflow source（部分落地）

当前已经可以把 active workflow version 和运行状态写入 SQLite。运行时目标是 DB active workflow version 作为唯一来源；split package 不再作为启动 fallback 或自动 seed。空库时系统应进入 setup-required，不开始监听、不调度 agent。当前已写入 SQLite 的内容包括：

- issue 快照
- run 状态
- agent turn 状态
- workspace 信息
- orchestrator events
- dashboard 所需历史数据

收益：

- dashboard 可以展示历史记录。
- 服务重启后可以恢复更多上下文。
- debug 不再完全依赖日志文件。

### 阶段 2：Web UI 管理配置

当前 Settings 已从早期 raw editor 演进为 tabbed configuration：`/settings/workflow` 承载结构化 draft form，`/settings/agents` 承载 profile 设置。可以从 runtime 或数据库 workflow
version 生成表单，编辑后保存为新的 workflow version。这个阶段仍是 `部分落地`：页面已经不再只是一个巨大纯文本框，但还没有完整覆盖字段级
verification、diff 审计、导出按钮和所有配置域的高级编辑。后续目标是继续把 workflow package 拆成更
完整的可编辑数据模型。拆分时必须覆盖整个文件，而不是只覆盖 prompt：

- project 配置
- tracker 配置
- polling 配置
- workspace 配置
- hook 配置
- agent 配置
- codex 配置
- server / dashboard 配置
- prompt template
- workflow states、review states、allowed transitions
- execution profiles、profile prompt policy、allowed updates

此阶段应支持 split package 上传导入和导出。页面级导入/导出入口和版本 diff
仍属于后续补齐项。早期 raw editor 不是长期目标入口；长期主入口应保持结构化表单。导入/导出是数据交换能力，不是运行时 source 选择。

Settings 页面长期应提供几个互相一致的 tab/入口：

- `/settings/workflow` 结构化编辑：默认入口。按 tracker、project/bootstrap、workspace、hooks、agent、codex、
  workflow routing、prompt 等区域编辑。
- `/settings/agents` 结构化编辑：编辑 profiles、base prompt、profile prompt、allowed updates 和 executor policy。
- `/settings/runtime` 运行时摘要：展示 tracker/config 摘要和运行时相关配置。
- 文件上传导入：上传 split package，解析后进入同一套结构化模型，显示校验结果；后续补齐
  与当前 active version 的 diff，校验通过后才能保存为新的 workflow version。

这些入口必须写入同一个 workflow version 模型。导入文件写入 DB version；导出文件来自 DB version；运行时只读取 DB active version，避免 UI 配置、文件配置和运行时配置分裂。
详细页面结构、verification 分层、上传导入流程和导出定位维护在
[Workflow 页面设计目标](workflow_page_design.zh-CN.md)。

### 阶段 2.0：三阶段执行 profile

Workflow 不是一个单一 agent prompt。长期至少要区分三个执行环节：

- `refinement`：从一句话想法和上下文细化任务，产出可人工确认的需求。
- `implementation`：拉取代码、建 worktree、实现、测试、验证、推分支并交给人验收。
- `merge`：合并或落地已验收结果；这个环节可以是 Codex agent，也可以是后端服务、GitHub
  automation、人工操作或 future worker，不应默认等同于前两个 Codex agent。

因此 workflow 应把“状态路由”和“执行 profile 定义”拆开：

- `workflow.states.<Linear state>.profile` 负责指定某个状态使用哪个 profile。
- `profiles.<profile_id>.name` 是 profile 的显示名称，也会进入 prompt、日志和诊断。
- `profiles.<profile_id>.executor` 指定执行器类型，例如 `codex_agent`、`backend_action`、
  `manual`、`external_worker`。
- `profiles.<profile_id>.prompt` 指定阶段专属 prompt 或 prompt template。
- `profiles.<profile_id>.tool_policy` 指定阶段专属 tool policy。
- `profiles.<profile_id>.allowed_updates` 指定允许的 Linear update 字段和 target states。
- `workflow.allowed_transitions` 和 review states 负责表达人工 review gate 以及被打回后的目标状态。

`refinement`、`implementation` 和 `merge` 的 prompt 不应强行共用同一个模板。默认 workflow
可以提供一个公共基础 prompt，但每个阶段必须能追加或替换阶段指令。尤其 merge 阶段要允许
关闭 Codex agent，只由后端执行受控 merge 或等待人工完成。

运行时长期只以 database workflow version 为 source，不再支持显式文件 runtime source，也不再展示 runtime/database mismatch 作为正常模式。split package 的推荐结构仍是
`workflow.yml` 放状态路由和运行配置，`profiles.yml` 放 base prompt 和执行定义，但它们只用于导入/导出。数据库 workflow version 必须自包含，不能依赖旁边的 profile 文件。逻辑结构是：

```yaml
workflow:
  states:
    Refining:
      profile: refinement
    Ready:
      profile: implementation
    In Progress:
      profile: implementation
    Ready to Merge:
      profile: merge
    Merging:
      profile: merge

profiles:
  refinement:
    name: "Refinement"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Refine the task into clear requirements and acceptance criteria.
    allowed_updates:
      description: true
      comment: true
      result: false
      target_states: ["Needs Refinement Review"]

  implementation:
    name: "Implementation"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Implement, test, verify, and prepare the work for human review.
    allowed_updates:
      description: false
      comment: true
      result: true
      target_states: ["In Progress", "Needs Implementation Review"]

  merge:
    name: "Merge"
    executor:
      type: manual
    prompt:
      mode: disabled
    allowed_updates:
      description: false
      comment: true
      result: true
      target_states: ["Done"]
```

`profiles.<id>.active_states` 不再作为状态路由来源。路由只能从 `workflow.states` 读取。
如果未来支持本地多文件导入，导入阶段也必须把多个文件解析成一个完整的数据库 workflow version
后再保存和激活。

阶段 prompt 的组合语义使用 `prompt.mode` 表达意图，不表达物理拼接方向。`extend` 表示保留
`profiles.yml` 里的公共 base prompt，并叠加 profile 专属 prompt；实际渲染顺序是先放阶段指令，
再放 base prompt。

- `extend`：使用 profile prompt 加 base prompt，渲染顺序是 profile template 在前、base prompt 在后。
- `replace`：只使用 profile prompt。
- `disabled`：只允许非 Codex executor 使用，不向 Codex 构造 prompt。

这个契约由 [046 Profile Prompt Mode Clarity](exec-plans/completed/046-profile-prompt-mode-clarity.md) 落地。

现状对齐：profile schema、state -> profile 路由、profile prompt mode、allowed updates 和
`codex_agent` 执行路径已经落地。`manual`、`backend_action`、`external_worker` 目前主要是配置
契约和调度过滤依据；Orchestrator 当前只自动领取并执行 `executor.type == "codex_agent"` 的状态。
因此“merge 可以不是 agent”在当前代码中表现为：把 merge profile 配成非 `codex_agent` 后，Symphony
不会自动启动 Codex；真正的 backend merge executor 仍属于阶段未到。

### 阶段 2.1：项目模板和 bootstrap 配置解耦

split package 样板不应该通过不可校验的 hook 字符串绑定 Symphony 自身仓库、Elixir
子目录、`mix` 命令或 `mise`。仓库来源必须出现在结构化 `project.repository_url`
里；如果这个字段缺失，运行配置应失败，调度器不应拉取 Linear 任务或启动任何工作。
Symphony 自身开发可以显式配置 `https://github.com/openai/symphony`，但这不是隐式默认值。

长期方向是把“项目工作区如何创建、如何初始化、如何清理”建模为显式的 project bootstrap
contract，而不是把它埋在不可校验的 shell hook 字符串里。最低可接受形态仍可以生成 hooks，
但模板来源必须是项目配置，而不是 Symphony 代码写死。

目标配置语义：

- `workspace.root` 只表示 Symphony 创建 issue workspace 的根目录。
- 项目代码来源应显式配置，例如必填的 `project.repository_url`、`project.default_branch`、
  `project.checkout_depth`。
- bootstrap 命令应按项目类型生成或配置，例如 Rust 项目的 `cargo fetch`、Elixir 项目的
  `mix deps.get`、Node 项目的 `npm ci`。
- cleanup 命令必须可选；没有项目级清理需求时不要默认运行语言专属命令。
- Web UI 和样板生成器应支持选择项目类型或直接填写 bootstrap commands。
- 生成出的 split package 必须让用户一眼看出需要替换 repo URL、workspace root 和项目命令。

推荐演进路径：

1. 先提供不绑定语言的通用样板，只保留 repo clone 和可选 bootstrap placeholders。
2. 再新增 project bootstrap schema，把 repo URL、branch、setup commands、cleanup commands
   结构化保存。
3. 最后让 Web UI 根据 bootstrap schema 生成 hooks，并在保存前校验危险或缺失配置。

### 阶段 3：配置版本化（已落地基础模型）

每次配置变更会生成新的 `workflow_versions` 记录。run/task 记录已经可以引用
`workflow_version_id`，后续仍需要完善 UI diff、审计展示和多项目维度。

这样可以回答：

- 某次 run 当时用了什么 prompt？
- 当时 Codex command 是什么？
- 当时 active states / terminal states 是什么？
- 当时 workspace root、hooks、poll interval、sandbox policy 是什么？
- 某次失败是否由配置变更引起？

### 阶段 4：多项目和多 worker

当前已经有默认 project、projects 页面、Panel 侧 worker/session/task/lease 数据模型和
worker HTTP API。这是 `部分落地`：数据模型和基础页面存在，但运行时仍以默认项目和当前 active
workflow 为主，完整多项目生产隔离还没完成。后续需要把这些能力从默认项目模型扩展到完整多项目生产路径：

- 多 project。
- 每个 project 独立 tracker 配置。
- 每个 project 独立 workflow version。
- 多 worker runtime。
- 不同 worker 的资源限制和安全策略。

## 7. Web UI 方向

Web UI 应优先服务运维、配置和调试，不做营销型页面。

Dashboard 的长期视觉语言应使用语义化配色，而不是临时页面级颜色。推荐采用 [Dashboard 配色系统设计](dashboard_color_system_design.zh-CN.md)：以杰尼龟蓝、小火龙橙、妙蛙种子绿和皮卡丘黄作为灵感来源，落地为 primary、warning、success、accent 等低饱和 CSS token。UI 不使用角色图片、商标素材或游戏化大面积装饰。

建议页面：

```text
/
├── Dashboard
├── Settings
│   ├── Projects
│   ├── Workflow
│   ├── Agents
│   └── Runtime
├── Issues
│   └── Issue Detail
├── Runs
│   └── Run Detail
├── Workspaces
├── Events
├── Logs
└── Settings
```

核心能力：

- 查看当前 orchestrator 状态。
- 查看 active runs、queued issues、backoff queue。
- 查看每个 issue 的 workspace、attempt、agent turn、最近事件。
- 查看 run 历史。
- 查看 workflow version 和配置 diff。当前已能查看版本历史和 active 状态，完整 diff UI 属于后续。
- 暂停/恢复 project。
- 手动 refresh tracker。
- 停止、重试、清理 run。
- 配置 Linear project slug、active states、terminal states。
- 配置 workspace root、hooks、Codex command。
- 编辑完整 workflow package contract 的结构化字段，包括 `workflow.yml` 和 `profiles.yml`。当前已覆盖核心字段，仍需补齐所有配置域和更细字段校验。
- 预览 workflow diff，并在保存前运行 schema 校验。当前已运行 schema 校验，diff 预览仍是后续。
- 查看每个 run 绑定的 workflow version 和原始 workflow 内容。

## 8. 安全方向

安全性不应主要依赖语言选择，而应依赖明确的执行边界。

长期应加强：

- Dashboard/API 鉴权。
- CSRF 和安全 header。
- secrets 不明文回显。
- Codex command 不默认继承全部环境变量。
- workspace root 路径严格校验。
- workspace 删除操作必须受路径约束。
- hooks 提供 UI 风险提示和审计记录。
- agent run 使用最小权限环境变量。
- 每个 run 记录审计事件。
- 支持本地 worker、Docker worker、SSH worker 等隔离等级。

建议安全模型：

```text
Phoenix Web / Orchestrator
└── Worker Runtime
    ├── Local Worker: 开发和可信环境
    ├── Docker Worker: 中等隔离
    ├── SSH Worker: 远程隔离
    └── Future Rust Sandbox Runner: 更强边界
```

Rust 的优先使用位置不是主 Web 服务，而是未来的 sandbox runner 或 worker launcher。

### Codex 和 Linear 的权限边界

Codex 不应直接持有 Linear API Key，也不应获得对 Linear 的通用 GraphQL 调用能力。长期生产形态
应由 Symphony 后端托管 Linear API 访问，并向 Codex 暴露窄权限、语义化的 task tools，例如读取当前
任务、追加当前任务评论、请求受控状态流转。

详细行为契约维护在 [Codex 与 Linear 交互行为设计](codex_linear_interaction.zh-CN.md)。

## 9. 性能方向

当前系统的性能瓶颈更可能来自：

- Linear API。
- Git 操作。
- Codex app-server 子进程。
- workspace 文件系统 I/O。
- 测试命令执行时间。

BEAM 本身不是主要瓶颈。短中期性能优化重点应放在：

- 控制并发。
- tracker polling 节流。
- 对外部 API 做 retry/backoff。
- 减少重复 workspace 初始化。
- 将大日志流写入文件或事件表，而不是全部放内存。
- dashboard 查询做分页。
- run/event 表加索引。
- 长任务与 Web 请求解耦。

## 10. Debug 和可观测性方向

长期应将 debug 从“看终端输出”升级为“看结构化运行历史”。

建议统一事件模型：

```text
event_type:
  workflow.loaded
  tracker.polled
  issue.discovered
  run.started
  workspace.created
  hook.started
  hook.finished
  codex.started
  codex.turn.started
  codex.turn.finished
  run.retry_scheduled
  run.failed
  run.completed
  workspace.cleaned
```

每条事件应包含：

- `project_id`
- `issue_identifier`
- `run_id`
- `attempt`
- `event_type`
- `payload_json`
- `inserted_at`

Dashboard 和 JSON API 都应基于同一套状态/事件数据，而不是各自拼装。

## 11. 模块边界建议

长期代码边界建议保持如下分层：

```text
lib/symphony_elixir/
├── orchestration/     # 调度、状态机、重试、run lifecycle
├── workflows/         # workflow config、version、prompt template
├── trackers/          # Linear 等外部 tracker adapter
├── workers/           # local/docker/ssh worker runtime
├── codex/             # codex app-server client 和 dynamic tools
├── persistence/       # Ecto schemas、repo、queries
├── observability/     # events、logs、telemetry
└── security/          # secrets、auth、policy、path safety

lib/symphony_elixir_web/
├── live/
├── controllers/
├── components/
└── presenters/
```

当前代码不需要一次性重构到这个结构；新增 persistence、Web UI、diagnostics 和 worker API 时
继续向这个边界靠拢即可。

## 12. 推荐路线图

### Milestone 1：持久化运行状态（已落地基础版）

- 已引入 `ecto_sqlite3`、Repo 和 migration。
- 已保存 projects、workflow_versions、issues、runs、agent_turns、workspaces、events，以及 worker 相关 task/lease/session 状态。
- Dashboard 已能读取 DB 中的 runs、workers、tasks、workflow versions 等历史/管理数据。
- 运行时目标是 DB-only workflow source。split package 保留为导入/导出格式，不作为启动或 fallback source。

### Milestone 2：Dashboard 升级（部分完成）

- 已有 `/` dashboard、`/runs`、`/workers`、`/settings`、`/settings/projects` 和 `/diagnostics/linear`。
- `/workers` 已提供 task cancel/requeue operator controls。
- 仍可继续增加 run detail、issue detail、events/logs 页面，以及更完整的分页/筛选。

### Milestone 3：配置 UI（raw workflow 基础路径已完成）

- 已有 projects 页面。
- 已有 `/settings/workflow` 结构化 draft form，可编辑核心 tracker、project/bootstrap、hooks、runtime、codex 和 state routing 字段，并保存为完整 workflow version。
- 已有 `/settings/agents` 设置 tab，可编辑 base prompt、profiles、profile prompt 和 allowed updates。
- 页面不再以 raw textarea 作为主要编辑入口；split package 导入/导出入口仍需补齐。
- 每次保存生成 workflow version，并可激活历史版本。
- 仍需补齐导出按钮、diff 审计、allowed transitions 完整编辑器、更多配置域和更细的字段级 verification。

### Milestone 4：安全和权限（部分完成）

- Dashboard/API 已支持可选 username/password 认证。
- Worker API 已使用独立 registration/session 协议认证。
- secrets metadata 入库。
- secrets 明文只通过受控注入路径使用。
- 增加 hook 审计事件。
- 收紧 Codex environment inheritance。

### Milestone 5：Worker Runtime 分层（Panel 侧已落地）

- 已支持 Panel / Worker 解耦的 Panel 侧路径：Panel 负责调度、配置、持久化和 UI，Worker 主动连接 Panel、握手、心跳、领取任务并回传结果。
- `SYMPHONY_EXECUTION_MODE=worker` 已使 orchestrator 将 issue 入队为外部 worker task。
- 生产 worker 按前序技术选型方向使用 Rust 或独立进程实现，并通过稳定 JSON/HTTP 协议接入 Panel。
- 详细设计见 [Panel / Worker 解耦设计](worker_panel_decoupling_design.zh-CN.md)。
- 已增加 worker identity、worker session、task queue、task lease、heartbeat、capability matching 和 dashboard worker 状态。
- 已实现 worker API 协议版本、预共享注册 token、租约续期、任务取消/requeue、task event 上报。
- 保留 local worker。
- 稳定 SSH worker。
- 增加 Docker worker。
- 评估是否需要 Rust sandbox runner。

## 13. 明确不做或暂缓

短期不建议：

- 整体重写为 Rust。
- 整体重写为纯 Erlang。
- 引入独立 Node 前端项目。
- 将 Dashboard 做成复杂 SPA。
- 过早支持多租户。
- 过早设计分布式数据库或多实例调度。

这些方向不是永远不能做，而是当前收益不足以抵消复杂度。

## 14. 总结

Symphony 的长期主线应是：

```text
保留 Elixir/Phoenix 主系统
继续完善 Ecto + SQLite 持久化
继续用 LiveView 构建 Dashboard 和配置 UI
在 split package 与 SQLite workflow versions 之间保持可导入、可编辑、可审计
运行时只读取 SQLite active workflow version
把安全隔离下沉到 worker runtime
必要时用 Rust 实现局部 sandbox/worker 组件
```

这条路线能最大化复用当前实现，同时兼顾安全性、性能、开发效率和调试成本。
