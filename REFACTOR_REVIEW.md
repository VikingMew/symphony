# Symphony 重构评估报告

日期：2026-08-08（Asia/Shanghai）

代码基线：`34ead573471288dce49004ca768b150eaf0bda88`

审查范围：先阅读 `AGENTS.md` 的 Code Value Principles，以及 `docs/ARCHITECTURE.md`、`docs/design.md`、`docs/spec.md`；随后静态盘点 `lib/` 的 147 个 `.ex` 文件（28,507 行），重点阅读大模块、配置/持久化/工作区安全边界、异常处理和 xref 依赖环。本报告只评估，不包含实现。

## 摘要

整体代码健康度中上：编译在 warnings-as-errors 下通过，Credo 没有 correctness/refactoring 级问题；大文件多数由短函数或 HEEx 组成，不能仅凭行数判定应拆。

真正集中的风险是“错误诚实性”：数据库故障仍可能呈现为 setup-required/空数据，磁盘门禁异常时会放行，多个审计事件写入点把失败吞成 `:ok`。

最值得动手的是修复磁盘门禁 fail-open、让 Workflow/Persistence 返回 typed error、统一审计事件写入的降级语义。

模块边界问题主要在 Web Settings 与 Persistence/Workflow 的依赖反向；建议做窄切口，不把 Orchestrator、Workspace 或 AppServer 按行数机械拆散。

## 🔴 高优先（值得进入跟踪任务）

### H1. 数据库故障仍会被投影成 setup-required 或“空数据”

- **文件:行**：`lib/symphony_elixir/workflow_store.ex:30-38, 176-186, 280-306`；`lib/symphony_elixir/config.ex:24-32`；`lib/symphony_elixir/persistence.ex:101-124, 147-203`；`lib/symphony_elixir/persistence/workflow_store.ex:36-40, 75-101, 137-159`；`lib/symphony_elixir/analytics.ex:89-110`；`lib/symphony_elixir_web/live/admin_live/runs.ex:19-20`。
- **问题**：`WorkflowStore` 初始加载遇到 `:repo_unavailable` 时构造了 `source: %{type: :error}`，但 `current/0` 永远返回 `{:ok, workflow}`，`state_payload/1` 又在没有 workflow 时塞入 `setup_required_workflow/1`。`Config.settings/0` 因此只看到 `:setup_required`。同时多个 Persistence 读 API 在 Repo 不存在时返回 `nil`、`[]` 或空分页，Analytics 再用 catch-all 把任何异常变成 `[]`；页面最终会显示“No persisted runs yet”或全零指标。这里同时存在“错误 source”和“setup workflow”两套互相矛盾的事实。热重载保留 last-known-good 的行为是正确的，问题在初始错误和读 API 的错误类型被抹掉。
- **违反原则**：**Explicit errors over silent tolerance**——AGENTS.md 明确禁止把数据库故障伪装成“setup required”；**Carmack: minimize the number of things that can go wrong**——同一状态被 `source: :error` 与 `workflow.setup_required: true` 双重表示。
- **建议动作：REFACTOR（重构）**。让 `WorkflowStore.current/0`、关键 list/get API 返回 `{:ok, value} | {:error, reason}`，以 sum type 明确区分 `no_active_workflow`、`repo_unavailable`、查询失败；首次加载失败直接暴露错误，热重载仍保留 last-known-good。Web/Analytics 显示“数据不可用”，不能显示“零数据”。
- **为何值得 / 风险**：这是运行时真相和运维诊断的基础，价值高于 API 改动成本。风险是调用方较多，应以一个跟踪任务逐层迁移并用断库测试锁定，不要一次顺带改查询模型。

### H2. 工作区磁盘安全门禁在自身异常时 fail-open

- **文件:行**：`lib/symphony_elixir/orchestrator.ex:1122-1136, 1219-1227, 1268-1281`；`lib/symphony_elixir/workspace_disk_guard.ex:10-23, 37-65`。
- **问题**：`WorkspaceDiskGuard.check/2` 已把 `df` 失败和解析失败建模为 `{:error, reason}`，但 `ensure_workspace_disk_available/1` 的 catch-all `rescue` 记录 warning 后返回 `:ok`。因此配置访问、guard 实现或意外异常会绕过安全门禁，issue agent 和 operator task 都继续启动。
- **违反原则**：**Explicit errors over silent tolerance**——安全门禁不能把评估失败当通过；**Carmack: minimize the number of things that can go wrong**——catch-all rescue 隐藏程序错误并扩大为磁盘/工作区风险。
- **建议动作：REFACTOR（重构）**。异常应规范化为 `{:error, %{reason: :disk_guard_evaluation_failed, ...}}`，复用现有 blocked/fail 路径并记录结构化上下文；绝不能返回 `:ok`。测试同时覆盖普通 issue 与 operator task。
- **为何值得 / 风险**：这是本报告价值/风险比最高的单点修复：改动面小、已有错误路径可复用、直接恢复安全不变量。

### H3. 审计/阶段事件写入有四套重复的“失败即成功”实现

- **文件:行**：`lib/symphony_elixir/agent_runner.ex:534-558, 566-585`；`lib/symphony_elixir/workspace.ex:971-990, 1004-1026`；`lib/symphony_elixir/merge_executor.ex:195-215`；`lib/symphony_elixir/codex/linear_tool_audit.ex:14-52`；对照正确实现 `lib/symphony_elixir/orchestrator.ex:2778-2837`。
- **问题**：这些路径直接调用 `record_event/1` 后无条件返回 `:ok`，既忽略 `{:error, reason}`，又用 `rescue _ -> :ok` 吞掉异常。结果可能是 workspace hook、merge phase、Linear restricted tool audit 或 agent phase 已执行，但没有记录，也没有降级标记。相同模式被手写多次；Orchestrator 已有会区分 `:repo_unavailable`、记录结构化失败并拒绝意外结果的较好语义，却未复用。
- **违反原则**：**Explicit errors over silent tolerance**——不能“pipeline 继续但没有记录且无痕”；**Linus: remove complexity, keep good taste**——同一错误策略复制四次；**Carmack: minimize the number of things that can go wrong**——catch-all rescue 扩散。
- **建议动作：MERGE（合并）**。提取一个具体的持久化事件写入入口（不是通用“万能错误框架”），统一返回 `:ok | {:degraded, reason} | {:error, reason}`、结构化日志和 issue/run/session 上下文。调用方可明确选择 best-effort，但 best-effort 必须可见；关键审计事件应决定是否使当前动作失败。
- **为何值得 / 风险**：能同时删除重复、补回审计可信度。风险在于不能把所有 telemetry 失败都升级成业务失败；应按事件类别显式制定强/弱一致性，而不是一个全局布尔开关。

## 🟡 中优先

### M1. Schema、setup sentinel 与 WorkflowForm 各自维护默认值，已经发生实际漂移

- **文件:行**：`lib/symphony_elixir/config/schema.ex:88-100, 199-211, 574-597`；`lib/symphony_elixir/config/runtime_resolver.ex:8, 55-62`；`lib/symphony_elixir/workflow.ex:72-99`；`lib/symphony_elixir/workflow_form.ex:20-64, 404-413`；`lib/symphony_elixir_web/admin/project_settings.ex:148-159`；规范见 `docs/spec-workflow-config.md:110, 312-318`。
- **问题**：规范/Schema 的 workspace 默认值是 `<system-temp>/symphony_workspaces`、最大并发是 `10`；空表单回退成硬编码 `/tmp/symphony-workspaces`（连分隔符都不同）和 `1`。`setup_required_workflow/1` 也写死并发 `1` 且缺 workspace。`normalized_display_config/1` 虽调用 `Schema.parse/1`，却只把 workflow/profiles 放回显示 config，因而没有真正把嵌套 Schema 默认值投影到表单。在 macOS 上 `/tmp` 与 `System.tmp_dir!()` 通常不是同一路径，首个保存版本会把 UI fallback 固化进数据库。
- **违反原则**：**Carmack: minimize the number of things that can go wrong**——同一默认事实多重表示；**Linus: remove complexity**——重复常量必须同步维护。
- **建议动作：REFACTOR（重构）**。由 `Config.Schema` 提供唯一的 typed defaults/外部 config 投影，WorkflowForm 和 ProjectSettings 只格式化该结果。若首次配置并发 `1` 是有意的产品策略，应命名为独立的 first-run policy 并测试/文档化，不能悄悄冒充 Schema 默认值。
- **为何值得 / 风险**：已有可观察漂移，修复价值明确；主要风险是改变首次配置体验，应先把“默认”与“首次引导策略”分开再迁移。

### M2. Force Stop 在任务取消失败时仍报告 `cancelled_tasks: 0`

- **文件:行**：`lib/symphony_elixir/orchestrator.ex:1784-1804, 2265-2276`。
- **问题**：`cancel_active_worker_tasks/0` 忽略每个 `cancel_task/2` 的错误，并用 catch-all rescue 把 list/query 异常变成 `0`；`force_stop_all` 随后把这个值作为成功结果与事件 payload 返回。`0` 同时表示“没有活动任务”和“数据库/取消操作失败”。
- **违反原则**：**Explicit errors over silent tolerance**；**Carmack: minimize the number of things that can go wrong**——控制面结果的双重含义会让 operator 误判。
- **建议动作：REFACTOR（重构）**。返回 `%{cancelled: n, failed: [...], status: :ok | :partial | :error}` 或 typed tuple；记录 task id/reason。已停止的本地进程无需回滚，但 API/UI 必须显示部分失败。
- **为何值得 / 风险**：这是运维控制的诚实性修复；不应为了“事务化”强行回滚已完成的 stop，保持部分成功即可。

### M3. 同一个 canonical descendant/symlink escape 算法在三个安全边界重复实现

- **文件:行**：`lib/symphony_elixir/workspace.ex:1034-1059`；`lib/symphony_elixir/codex/app_server.ex:184-259`；`lib/symphony_elixir/workspace_cleanup_policy.ex:18-52, 91-110`；现有底层工具 `lib/symphony_elixir/path_safety.ex:1-48`。
- **问题**：三处都在 canonicalize roots、拒绝 exact root、判断 descendant、区分 symlink escape/outside root，分别手写 `String.starts_with?(path <> "/", root <> "/")` 及 root 列表规约。允许的 roots 和错误类型有合理差异，但安全算法本身重复，未来修复 symlink/路径边界时容易只改一处。
- **违反原则**：**Linus: remove complexity**——同一算法重复；**Carmack: minimize the number of things that can go wrong**——安全不变量漂移。
- **建议动作：MERGE（合并）**。把“canonical path 是否严格位于任一 canonical root 下”的原语放进 `PathSafety`，Workspace、AppServer、CleanupPolicy 保留各自 policy 和错误映射。不要合并本地/远端策略，也不要创建可配置的通用策略 DSL。
- **为何值得 / 风险**：安全代码去重有价值，但重构本身也有安全风险；必须用 exact-root、nonexistent leaf、relative symlink、absolute symlink、outside-root 表驱动测试先锁行为。

### M4. Web consumer 反向调用 Endpoint 配置，形成唯一 compile-connected cycle

- **文件:行**：`lib/symphony_elixir_web/endpoint.ex:32`；`lib/symphony_elixir_web/router.ex:47-86`；`lib/symphony_elixir_web/live/dashboard_live.ex:528-544`；`lib/symphony_elixir_web/live/admin_live.ex:167-169`；`lib/symphony_elixir_web/controllers/observability_api_controller.ex:56-62`。
- **问题**：Endpoint compile-time plug Router，Router 引用 LiveView/Controller，而这些 consumer 又调用 `Endpoint.config/1`。orchestrator/timeout resolver 还在 Dashboard 与 API Controller 重复。xref 将其识别为长度 6、含 1 条 compile edge 的环。
- **违反原则**：**Linus: remove complexity**——依赖方向不清且 helper 重复；**Carmack: hard to make simple is still worth it**——Web 叶子反向依赖启动边界使编译和测试耦合。
- **建议动作：MERGE（合并）**。用一个独立、窄的 Web runtime accessor 或 mount/conn 注入提供 orchestrator 与 timeout，让 Endpoint 只依赖 Router，页面/Controller 不再调用 Endpoint。两个配置键、三个消费者已经足以让这个小边界赚回成本，不要扩展成通用 service locator。
- **为何值得 / 风险**：能移除唯一 compile-connected 环并删重复代码；行为风险低，重点是保留测试对自定义 orchestrator/timeout 的注入能力。

### M5. Settings 已拆成多文件，但 Shell、子页和状态模块仍互相回调

- **文件:行**：`lib/symphony_elixir_web/live/admin_live/settings_shell.ex:6-9, 202-206`；`lib/symphony_elixir_web/live/admin_live/settings/agents.ex:6-11`；`lib/symphony_elixir_web/live/admin_live/settings/workflow.ex:6-14`；`lib/symphony_elixir_web/live/admin_live/state.ex:17-25, 45`；`lib/symphony_elixir_web/live/admin_live/workflow_state.ex:15-17, 34-58, 95-122`；`lib/symphony_elixir_web/live/settings_live.ex:1-23`。
- **问题**：SettingsShell 引用五个 page modules 来渲染，page modules 又 import SettingsShell 的组件；State 调 WorkflowState，WorkflowState 保存后再调 State.refresh。xref 报告长度 7 的 export/runtime 环。与此同时 `SettingsLive` 四个 callback 全量转发给 `AdminLive`，是一个尚未真正拥有状态或事件的“route boundary”。
- **违反原则**：**Linus: remove complexity**——单实现转发层和双向依赖没有当前消费者价值；**Carmack: hard to make simple is still worth it**——保存/刷新流程需要在多个模块间来回追踪。
- **建议动作：SPLIT + DELETE（拆分 + 删除）**。把共享组件/导航提到无 page 依赖的 leaf module；让 WorkflowState 返回保存结果，由 LiveView owner 单向调用 refresh。当前最简单选择是删除只转发的 `SettingsLive` 并直接路由到 `AdminLive`；只有在本次就完整迁走 state/events 时才应保留它作为真实 owner。
- **为何值得 / 风险**：目标是把依赖改成单向，不是继续增加 Settings 小模块。拆 component 与删除 wrapper 可分步完成；不要借机重写全部 HEEx。

### M6. DB-only runtime 仍保留单值 source selector 和跨层兼容入口

- **文件:行**：`lib/symphony_elixir/cli.ex:25-31, 61-64, 73-80, 191-198`；`lib/symphony_elixir/workflow_store.ex:198-200, 260-262`；`lib/symphony_elixir/workflow.ex:47-70`。
- **问题**：CLI 的 deps map 包含 `set_workflow_source`，实现只接受 `:database`，每次启动都把这个唯一值写进 Application env；WorkflowStore 又接受 `nil | :database | "database"`，其他值静默进入 setup-required。与此同时 package parser 模块 `Workflow` 通过一行 `current/0` 反向依赖 runtime Store。当前架构已经明确 SQLite active workflow 是唯一 runtime authority，这些选择分支不再提供选择。
- **违反原则**：**Linus: remove complexity**——只有一个合法值的配置/分支没有消费者；**Carmack: minimize the number of things that can go wrong**——非法 selector 被解释成 setup-required，再次制造双重含义。
- **建议动作：DELETE（删除）**。删除 CLI setter/deps 字段和 `database_workflow_enabled?/0`，WorkflowStore 无条件走 DB。让 runtime caller 直接依赖 WorkflowStore，`Workflow` 保持 package parse/render 职责。`Workflow.load/1`、`parse_split_package/2`、`parse_content/1` 等 import/export codec 不应随之删除。
- **为何值得 / 风险**：生产行为只有一个，删除分支可直接证明等价。大量测试使用 file loader 作为 fixture builder，迁移它们不属于本项，避免把低价值测试 churn 混进 runtime 清理。

### M7. Persistence façade 与其子 context 反向依赖，边界呈环而非单向

- **文件:行**：`lib/symphony_elixir/persistence.ex:23-62, 308-358`；`lib/symphony_elixir/persistence/workflow_store.ex:9-11, 15-57`；`lib/symphony_elixir/persistence/worker_queue.ex:7-12, 47-80`；`lib/symphony_elixir/persistence_provider.ex:1-14`。
- **问题**：父 façade `Persistence` delegate 到 `Persistence.WorkflowStore`/`WorkerQueue`，两个子 context 又调用父 façade 的 `repo_available?/0`，WorkerQueue 还通过父 façade 回调 `default_project/0`。xref 的长度 6 persistence/workflow 环包含这组反向边和 Workflow runtime/package 混合边。Provider 本身是合理测试 seam，问题不是 Provider，而是子模块回到父 API。
- **违反原则**：**Linus: remove complexity**——依赖方向不清；**Carmack: minimize the number of things that can go wrong**——环使错误 contract 和初始化顺序更难推理。
- **建议动作：REFACTOR（重构）**。保留 Persistence 作为外部 façade，但内部 context 只依赖 Repo/同层 context：Repo availability 放到真正拥有 Repo 生命周期的窄入口，WorkerQueue 直接调用同层 WorkflowStore 获取 default project。结合 H1 一次性统一 typed read contract；不要再加第二个 façade。
- **为何值得 / 风险**：可减少 xref 环并让错误语义有唯一所有者。单独为“图变绿”重排模块不值得，应与 H1 的 contract 迁移同一计划完成。

## 🟢 低优先（顺手改）

### L1. Orchestrator 的 `completed` MapSet 只写不读，还会随进程生命周期增长

- **文件:行**：`lib/symphony_elixir/orchestrator.ex:116-141, 379-390, 1260-1265`；唯一直接观察者是测试 `test/symphony_elixir/core_test.exs:1183-1186`。
- **问题**：完成后把 issue id 写入 `state.completed`，生产代码、snapshot 和 dispatch policy 从不读取它；真正继续行为由 retry entry 驱动。长运行进程会保留所有完成 id。
- **违反原则**：**Linus: talk is cheap, show me the code**——删除无人使用的分支/状态是最直接验证；**Carmack: minimize the number of things that can go wrong**——无界但无语义的第二份生命周期记录。
- **建议动作：DELETE（删除）**。删除字段、`complete_issue/2` 以及只验证内部实现的测试断言，保留删除 retry state 与 continuation scheduling。
- **为何值得 / 风险**：改动小、无外部 contract；不值得单独开大型任务，可随 Orchestrator 相关修改完成。

### L2. Tracker adapter resolver 有一个未使用值的隐藏配置副作用

- **文件:行**：`lib/symphony_elixir/tracker.ex:41-45`。
- **问题**：`adapter/0` 执行 `_settings = Config.settings!()` 后始终返回 `Linear.Adapter`。变量未被读取，调用者却可能因配置异常在“选择 adapter”时抛错；Orchestrator 自身已经在 poll/dispatch 前验证 runtime config。
- **违反原则**：**Linus: remove complexity**——无消费者的读取；**Carmack: minimize the number of things that can go wrong**——隐藏副作用让边界行为不直观。
- **建议动作：DELETE（删除）**。删除该读取；Tracker 行为与 Linear.Adapter 边界本身保留。
- **为何值得 / 风险**：机械、低风险；先确认没有测试刻意依赖这个异常时机即可。

### L3. DynamicTool 用 throw/catch 传递普通验证错误

- **文件:行**：`lib/symphony_elixir/codex/dynamic_tool.ex:302-319, 466-472`；`lib/symphony_elixir/codex/dynamic_tool/policy.ex:6-19`。
- **问题**：state lookup 与参数字段错误通过 `throw` 跨越普通调用栈，再由外层 `catch` 转回 `{:error, ...}`。这些都是预期业务错误，非本地控制流增加了阅读成本，也容易在未来重排 helper 时漏 catch。
- **违反原则**：**Carmack: hard to make simple is still worth it**——普通错误应沿 `with`/pattern matching 显式返回；**Carmack: minimize the number of things that can go wrong**——非本地跳转增加隐式出口。
- **建议动作：REFACTOR（重构）**。让 `maybe_put_state_id/4` 和字段归一化返回 `{:ok, value} | {:error, reason}`，纳入已有 `with`。
- **为何值得 / 风险**：仅是局部可读性提升，不影响当前正确性；只应在修改 DynamicTool 时顺手完成。

## 建议保持不动

### K1. `orchestrator.ex` 不应仅因 2,891 行就拆成多个进程

- **文件**：`lib/symphony_elixir/orchestrator.ex`。
- **看起来像债务**：全仓最大文件、20 个 outgoing dependencies，并拥有 polling、dispatch、retry、operator tasks、snapshot、persistence 协调。
- **建议动作：KEEP-AS-IS（保持）**。它是规范指定的单一 coordination/state owner；多数函数较短，Credo 没有 nesting/complexity 告警。把状态分散到多个 GenServer 会新增消息顺序、重试和清理竞态。应只做 H2、M2、L1 这类可证明的窄修改；纯 policy 已有 `DispatchPolicy`、`RetryPolicy`、`SessionHistory` 等模块。不要以“每 500 行一个模块”为目标。

### K2. `workspace.ex` 不宜整体拆散

- **文件**：`lib/symphony_elixir/workspace.ex`（1,103 行）及 `workspace/source_preparation.ex`、`workspace/hook_runner.ex`、`workspace/remote.ex`、`workspace_cleanup_policy.ex`。
- **看起来像债务**：同时处理 clone/worktree、hooks、local/remote 与 cleanup。
- **建议动作：KEEP-AS-IS（保持 public façade）**。工作区安全要求路径验证、创建、hook 和删除顺序保持可追踪，且纯命名、command runner、remote 与 destructive policy 已经有真实拆分。M3 只合并底层路径关系算法；没有第二套 workspace backend 前，不要再加 strategy behaviour 或通用生命周期框架。

### K3. AppServer/Protocol 的长 receive loop 是协议状态机，不是应拆的 god object

- **文件**：`lib/symphony_elixir/codex/app_server.ex`（817 行）、`lib/symphony_elixir/codex/protocol.ex`（463 行）。
- **看起来像债务**：`run_turn`、incoming message handling 较长，兼容多种 Codex method/payload。
- **建议动作：KEEP-AS-IS（保持）**。process/port 所有权和 session state 集中有助于正确性，协议解析、startup、tool request 已分离。继续拆 receive loop 会迫使更多 session 字段跨模块传递；外部 JSON 的 string-discriminated map 也是边界数据，不应为了“用 struct”先复制一遍。

### K4. Config.Schema 大，但它是唯一规范性 typed contract

- **文件**：`lib/symphony_elixir/config/schema.ex`（808 行）。
- **看起来像债务**：包含多个 nested embedded schema 和大量默认/验证逻辑。
- **建议动作：KEEP-AS-IS（保持）**。这里的聚合与 `docs/design.md` 对 Config boundary 的定义一致；静态引用扫描未发现明显零使用配置字段。把每个 20–50 行 embedded schema 拆成文件只会增加导航与 export dependency。M1 应让其他层回归它，而不是拆散它。

### K5. 大型 HEEx render 与纯 read-model 模块不应按 LOC 拆

- **文件**：`lib/symphony_elixir_web/live/dashboard_live.ex`（549 行）、Settings 各 page、`lib/symphony_elixir/run_history.ex`（586 行）、`lib/symphony_elixir/run_summary.ex`。
- **看起来像债务**：Dashboard 的 render 约 400 行，RunHistory 分支很多。
- **建议动作：KEEP-AS-IS（保持）**。HEEx 是同一页面布局，RunHistory/RunSummary 是无副作用的协议投影；当前拆成只用一次的小组件/helper 会增加跳转而不减少状态。仅在出现第二个复用消费者或独立交互状态时提取。

### K6. Tracker behaviour 与 PersistenceProvider 虽各只有一个 production 实现，仍有当前价值

- **文件**：`lib/symphony_elixir/tracker.ex`、`lib/symphony_elixir/linear/adapter.ex`、`lib/symphony_elixir/persistence_provider.ex`。
- **看起来像债务**：one-implementation abstraction，xref 也有 Tracker ↔ Linear.Adapter 的长度 2 环。
- **建议动作：KEEP-AS-IS（保持）**。Tracker/Linear 是规范明确的 integration boundary，behaviour 提供编译期 contract；PersistenceProvider 有 18 个 incoming dependencies，并被大量 fake-persistence 测试使用。现在不要增加 adapter registry/配置，也不要为了消除图上的 runtime/export 环合并边界；只删除 L2 的隐藏读取。

### K7. RateLimitGate 的“无 snapshot 时允许”不能机械改成全局 fail-closed

- **文件**：`lib/symphony_elixir/codex/rate_limit_gate.ex:14-35, 57-91`；`lib/symphony_elixir/orchestrator.ex:2422-2429`。
- **看起来像债务**：`nil`、非 map 或未知 bucket 会返回 `:allow`，表面上像 fail-open。
- **建议动作：KEEP-AS-IS（保持现有 bootstrap 语义）**。首次 session 启动前本来没有 Codex rate-limit snapshot；若此时阻塞，将永远无法获得第一份 snapshot。意外的 gate 代码异常已在 Orchestrator 中 fail-closed 并记录 error。可以未来区分“从未收到”与“已收到但无法解析”，但不能把两者一刀切。

### K8. Workflow 的 package codecs 应保留

- **文件**：`lib/symphony_elixir/workflow.ex:102-371`、`lib/symphony_elixir/workflow_settings_package.ex`。
- **看起来像债务**：runtime 已 DB-only，仍保留 YAML/front-matter/split package 解析。
- **建议动作：KEEP-AS-IS（保持 codec）**。架构明确 `workflow.yml`/`profiles.yml` 是 import/export artifacts；Settings import/export 和 parser boundary 仍消费这些函数。M6 删除的是 runtime source selector 与反向 `current` 入口，不是文件格式能力。

## 客观信号

### 规模与热点

```text
lib/*.ex files: 147
total lines:     28,507

orchestrator.ex          2,891
workspace.ex             1,103
codex/app_server.ex        817
config/schema.ex           808
codex/dynamic_tool.ex       634
workflow_form.ex            596
run_history.ex              586
agent_runner.ex             586
dashboard_live.ex           549
```

行数只用于定位，不直接作为 finding。抽样函数长度和 Credo 结果表明，大文件主要是许多短 handler/helper 或 HEEx；没有证据支持全量拆分。

### 编译

命令：`mise exec -- mix compile --warnings-as-errors`

```text
exit 0
(no output)
```

结论：当前基线无编译 warning。

### Credo

命令：`mise exec -- mix credo --strict`

```text
Checking 265 source files
4002 mods/funs, found 22 code readability issues, 1 software design suggestion.
exit 6
```

- `[F] 0`；`[R] 22`；`[D] 1`。
- 22 个 readability 中包含测试；生产代码主要是 3 个 one-clause `with ... else`、若干超长行和 alias 顺序。
- 唯一 `[D]` 是 `status_dashboard.ex:262` 的 nested module alias 建议。
- 没有 Credo complexity/refactoring 级信号支持“因为大就拆”。这些格式/alias 项不值得独立任务，触碰相应文件时顺手修即可。

### Xref

命令：`mise exec -- mix xref graph --format stats`

```text
Tracked files:         147
Compile dependencies:   3
Exports dependencies:  37
Runtime dependencies: 363
Cycles:                  6

Top outgoing:
  orchestrator.ex 20
  router.ex       13
  admin_live.ex   12
  app_server.ex   12
  agent_runner.ex 12
```

命令：`mise exec -- mix xref graph --format cycles`

```text
length 7: Settings page/shell/state/workflow_state cycle (2 export)
length 6: Endpoint/Router/AdminLive/DashboardLive/SettingsLive/API cycle (1 compile)
length 6: Persistence/WorkerQueue/Workflow/PersistenceProvider/WorkflowStore cycle
length 3: Orchestrator/DispatchPolicy/StatusDashboard cycle (1 export)
length 3: Config ProjectCommands/Schema/WorkflowContract cycle (2 export)
length 2: Tracker/Linear.Adapter cycle
```

判断：前 3 个有本报告对应的单向化建议；后 3 个主要由 nested type ownership、规范性 contract 或明确 integration boundary 构成，不应只为 cycle count 重排。

命令：`mise exec -- mix xref warnings`

```text
** (Mix) xref doesn't support this command. For more information run "mix help xref"
exit 1
```

当前 Elixir/Mix 版本不提供该子命令；`xref graph` 已成功，未把不支持命令当代码问题。

### 静态引用与配置扫描

- `State.completed` 在生产代码中只有初始化和写入，没有读取；唯一直接读取是测试内部状态断言。
- `workflow_source` 的生产 setter 只接受/写入 `:database`，没有第二个 runtime source。
- `Workflow.workflow_file_path/load` 在 `lib/` 没有 runtime caller，主要服务测试 fixture/package parsing；因此报告只建议删除 runtime selector/反向入口，保留 codecs。
- Schema 字段逐项搜索未发现明显“定义后零读取”的配置项；不能把整个 Schema 拆分或删字段作为有效 finding。

## 总结

如果只做 3 件事，按价值/风险比排序：

1. **修复 workspace disk guard fail-open**：任何评估异常都进入 typed blocked/error 路径；改动最小，安全收益最大。
2. **让 WorkflowStore/Persistence 对数据库故障返回 typed error**：保留 reload 的 last-known-good，但首次故障和读失败不再冒充 setup-required/空数据。
3. **合并审计事件写入语义**：删除四套 `rescue _ -> :ok`/忽略返回值实现，显式区分成功、可见降级和关键失败。

默认值收敛、Web/Settings 单向依赖与 Persistence 内部边界应随后处理；不要先做 Orchestrator/Workspace/AppServer 的大拆分。
