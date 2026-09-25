---
title: Symphony 用户运行指南
genre: guide
domain: [operations, configuration]
status: current
language: zh-CN
updated: 2026-09-23
owner: SymphonyElixir.CLI
---

# Symphony 用户运行指南

这份指南说明如何在 macOS 和 Ubuntu 上安装依赖、配置 PostgreSQL、执行 migration，并启动 Symphony Web 服务。生产 Compose 运维见 [Compose 与 PostgreSQL 运维指南](compose.md)。

## 1. 前置要求

Symphony Elixir 需要：

- Git
- mise
- Erlang / Elixir，通过 `mise install` 安装
- Linear API Key
- Codex CLI，且支持 `codex app-server`
- PostgreSQL 17（服务端或可访问实例，以及 `psql` 客户端）
- SQLite CLI（仅旧数据库停机导入时需要）

项目声明的运行时版本在 `mise.toml`：

```toml
[tools]
erlang = "28"
elixir = "1.19.5-otp-28"
```

## 2. macOS 安装依赖

推荐使用 Homebrew：

```bash
brew install git mise postgresql@17 sqlite
```

初始化 mise shell：

```bash
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

验证：

```bash
mise --version
psql --version
```

如果没有 Homebrew，可以使用 mise 官方安装脚本：

```bash
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

## 3. Ubuntu 安装依赖

安装系统依赖：

```bash
sudo apt update
sudo apt install -y git curl build-essential autoconf m4 libncurses5-dev libssl-dev libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils postgresql-client sqlite3
```

安装 mise：

```bash
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc
```

如果你使用 zsh：

```bash
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

验证：

```bash
mise --version
psql --version
```

## 4. 安装项目运行时和依赖

进入 Elixir 实现目录：

```bash
cd /path/to/symphony/elixir
```

信任并安装 mise 声明的 Erlang/Elixir：

```bash
mise trust
mise install
mise exec -- elixir --version
```

安装 Elixir 依赖：

```bash
mise exec -- mix setup
```

构建可执行文件：

```bash
mise exec -- mix build
```

## 5. 配置环境变量

必须配置 Linear API Key：

```bash
export LINEAR_API_KEY="你的 Linear Personal API Key"
```

实现交付还需要 Symphony runtime user 的 GitHub 认证。优先让 service environment 中的 `gh`
已登录；也可以设置 REST fallback token：

```bash
export GH_TOKEN="你的 GitHub token"
# 或 export GITHUB_TOKEN="你的 GitHub token"
```

不要把 GitHub token 写进 workflow。中心化 SSH execution 时，worker 仍需单独具备 feature branch
push auth；初次 PR lookup/create 由 Symphony service 完成。

必须配置 PostgreSQL 连接。数据库必须已经存在；Symphony 不创建数据库。

```bash
export DATABASE_URL="postgres://symphony:replace-me@127.0.0.1:5432/symphony"
export SYMPHONY_DATABASE_POOL_SIZE=5
```

可选：启用 Web UI 登录认证。

```bash
export SYMPHONY_AUTH_ENABLED=true
export SYMPHONY_ADMIN_USERNAME=admin
export SYMPHONY_ADMIN_PASSWORD="请换成你自己的密码"
```

如果不设置 `SYMPHONY_AUTH_ENABLED=true`，认证默认关闭，适合本地临时开发，不建议用于共享机器或可被其他人访问的网络环境。

## 6. 初始化 PostgreSQL

由管理员创建数据库和账号后，首次运行及每次升级前执行 migration：

```bash
mise exec -- mix symphony.migrate
```

命令缺少 `DATABASE_URL`、连接不可达或 migration 失败时会显式失败，不会伪装成
setup-required。setup-required 表示数据库可用，但 instance workflow singleton 或 enabled project
workflow slice 尚未齐备。

## 7. 配置 workflow

运行时配置由 PostgreSQL 中唯一的 `app_settings["instance_workflow"]` 与每项目唯一的 tracker/source
workflow slice 组合而成。任一 scope 缺失都会进入 setup-required，不会监听 Linear 或调度 agent；
先在 `/settings/import` 显式导入 combined package。

`workflow.yml` 和 `profiles.yml` 是 split workflow package 的导入/导出格式，不是启动参数，也不
是运行时 fallback。这个 package 由两个文件组成：

```text
workflow.yml
profiles.yml
```

空数据库第一次配置时，在 Settings 的 Import 页面逐个粘贴 `workflow.yml` 或
`profiles.yml` 的内容导入到结构化 draft。Symphony 会根据 YAML
顶层字段自动识别 package 类型：包含 `profiles` 或 `base_prompt` 的文档按 `profiles.yml` 导入，其余
有效 workflow mapping 按 `workflow.yml` 导入。导入只填充页面上的 draft，不会立即激活运行时；确认校验提示后，
再点 Save；Symphony 在一个事务中写 instance singleton 和所选 project slice。
setup-required 页面里的提示文案只是系统状态提示，不是 base prompt。正确的 base prompt 来自
`profiles.yml` 的 `base_prompt`。

`workflow.yml` 里最少需要确认这些字段：

```yaml
tracker:
  kind: linear
  project_slug: "你的 Linear project slug"
workspace:
  root: ~/code/symphony-workspaces
  initialize_timeout_ms: 60000
project:
  repository_url: "git@github.com:your-org/your-repo.git"
  default_branch: "main"
  checkout_depth: 1
  source_strategy: "clone"
  setup_commands: []
  cleanup_commands: []
codex:
  pre_start_commands: []
  command: codex app-server
workflow:
  states:
    Refining:
      profile: refinement
    Ready:
      profile: implementation
    In Progress:
      profile: implementation
  human_review_states: ["Needs Refinement Review", "Ready to Merge", "Blocked"]
  allowed_transitions:
    - {from: Refining, to: Needs Refinement Review, actor: codex, profile: refinement}
    - {from: Ready, to: In Progress, actor: codex, profile: implementation}
    - {from: In Progress, to: Ready to Merge, actor: codex, profile: implementation}
    - {from: Ready to Merge, to: In Progress, actor: human, profile: implementation}
    - {from: Todo, to: Blocked, actor: symphony}
    - {from: Refining, to: Blocked, actor: symphony}
    - {from: Ready, to: Blocked, actor: symphony}
    - {from: In Progress, to: Blocked, actor: symphony}
    - {from: Ready to Merge, to: Blocked, actor: symphony}
    - {from: Blocked, to: Ready, actor: human}
    - {from: Blocked, to: Needs Refinement Review, actor: human}
    - {from: Blocked, to: Canceled, actor: human}
  tool_policy:
    linear:
      exposed_tools: ["linear_task_read", "linear_task_update"]
      raw_graphql: false
```

`profiles.yml` 里配置共享 base prompt 和 agent profile：

PostgreSQL instance singleton 是 base prompt 与所有 profiles 的唯一 durable authority；
`profiles.yml` 只是默认导入/导出 artifact。无论项目或目标仓库为何，refinement / implementation prompt 最终都会附加不可由
profile 覆盖的容器验证安全契约：agent 只能静态审阅 Dockerfile、Compose YAML 和 CI 配置，
不得调用容器引擎、daemon/socket 或执行镜像 build/pull/run/push/inspect/publish。若任务把
此类验证列为必需项，agent 必须记录 blocker evidence 并沿持久 `blocking_decision` / `Blocked`
路径 fail closed；其余允许的 ticket validation 仍必须执行。

```yaml
base_prompt: |
  You are working on a Linear issue {{ issue.identifier }}.

  Title: {{ issue.title }}
  Description:
  {{ issue.description }}

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
        Implement, test, verify, and commit the exact Linear branch. If the issue description's
        first non-empty line is exactly `交付路径:宿主 push`, write a complete binary-safe root
        `<issue-identifier>.patch`, do not push or call create_pull_request, and report
        `需宿主 push`. Otherwise push the exact branch, call create_pull_request with a
        docs/pull-request-body.md-conformant title/body, and submit the handoff evidence.
    allowed_updates:
      description: false
      comment: true
      result: true
      target_states: ["In Progress", "Ready to Merge"]
```

operator 判断 implementation 交付路径时，以 issue description 的首个非空行是否精确等于
`交付路径:宿主 push` 为准，必须使用 ASCII 冒号。普通路径由 worker push 精确 Linear branch、调用
`create_pull_request` 并提交 handoff evidence，门禁通过后进入 `Ready to Merge`。host-push 路径还要求
workspace 根存在完整、binary-safe 的 `<issue-identifier>.patch`；worker 完成本地 commit 与允许的
validation 后不 push、不创建 PR，也不会成功 handoff 或进入 `Ready to Merge`。executor 会记录包含
根相对 patch 路径与 `需宿主 push` 的 blocked / `handoff_failed` 证据；宿主据此接续 push 分支并创建
PR。精确判据和证据格式以
[Codex/Linear implementation workflow design](codex-linear-implementation-workflow-design.md) 与
[execution runtime design](execution-runtime-design.md) 为准。

`workspace.root` 是 Symphony 管理 issue workspace 的根目录，不是你的项目仓库目录。默认
`source_strategy: clone` 会在这个目录下为每个 Linear issue 创建子目录，然后把
`project.repository_url` 指向的仓库 clone 到该 issue workspace 中。`project.repository_url` 是运行必填项；缺失或为空时
workflow 配置校验失败，Symphony 不会拉取 Linear 候选任务或启动 agent。
`workspace.initialize_timeout_ms` 控制项目初始化阶段的超时，包括 clone/worktree 准备和
`project.setup_commands`；这些 workflow-only 字段可通过 Settings / Import 导入 workflow package。
`hooks.timeout_ms` 只控制
after_create、before_run、after_run、before_remove 等 lifecycle hooks。

如果同一个本地机器会同时处理很多同仓库任务，可以在 Project Settings 里把 source strategy 设为
`worktree`。长期路径模型见 `docs/workspace-source-layout-design.md`：共享 Workspace/Runtime Settings
应分别配置 repository base root 和 worktree base root。Project Settings 只配置 repository URL、
default branch、checkout depth、source strategy 等项目自身信息。Symphony 会把 `project.repository_url` clone/fetch 到
`repository_base_root / repo_cache_name`，再为每个 issue 创建
`worktree_base_root / issue_identifier`。clone/worktree 命令不应该写进 `hooks.after_create` 或
`hooks.before_run`。如果启用了 Fetch before worktree，每次 agent start 都会先 fetch 配置的
`project.default_branch`，并把托管 base repository 的本地默认分支更新到 `origin/<default_branch>`，
然后再创建 issue worktree。

如果 Codex 不在默认 PATH 中，使用 `codex.pre_start_commands`，不要把这些命令写进 lifecycle hook。
这些命令和最终 `codex.command` 在同一个 shell 里执行，因此 `source ~/.nvs/nvs.sh`、
`nvs use 22 >/dev/null`、`export PATH="$HOME/.local/bin:$PATH"` 这类环境准备会影响后续
`codex app-server`。`codex.command` 只负责启动 app-server；Codex model 与 reasoning effort
在 Settings / Runtime 通过枚举 selector 呈现并联动，通过 Settings / Import 导入
`workflow.yml` 的 `codex.model` / `codex.reasoning_effort` 后保存。普通 Runtime submit 会以
typed rejection 拒绝 instance-owned `codex` 字段；Import 保存后重载 Runtime 可回读，且只影响
后续 turn/session。selector 与 workflow validation 共用随 bundled `codex-cli 0.156.0` pin 派生的
code-owned catalog；当前七行依次为 `gpt-6-astra`、`gpt-6-sol`、`gpt-6-luna`、
`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` 和 `gpt-5.5`：

不要在 `codex.command` 使用 `-c` / `--config model=...`、
`-c` / `--config model_reasoning_effort=...` 或 `-m` / `--model`。workflow validation 会把它作为
`codex.command` 配置错误，并在 Settings / Runtime 标记对应 selector。Runtime 的空 model 选项表示
使用 Codex 默认 model；空 effort 选项表示使用所选 model 或 Codex 默认 effort。Settings / Import
仍接受这类已知 legacy command：review diff 会显示 command 清理与缺失 selector 的提升，显式导入的
selector 优先；确认并保存后 PostgreSQL current workflow 只保留干净 command 与结构化 selector。

```yaml
codex:
  pre_start_commands:
    - source ~/.nvs/nvs.sh
    - nvs use 22 >/dev/null
  command: codex app-server
  model: gpt-6-astra
  reasoning_effort: ultra
```

Rust 项目可以这样写 bootstrap：

```yaml
project:
  repository_url: "git@github.com:your-org/your-rust-repo.git"
  default_branch: "main"
  checkout_depth: 1
  source_strategy: "clone"
  setup_commands:
    - cargo fetch
  cleanup_commands: []
```

Elixir 项目才应该使用 Elixir 专属命令，例如：

```yaml
project:
  repository_url: "git@github.com:your-org/your-elixir-repo.git"
  source_strategy: "clone"
  setup_commands:
    - mise trust
    - mise exec -- mix deps.get
  cleanup_commands:
    - mix workspace.before_remove || true
```

每次 agent start 都会重新创建该 issue workspace；`clone` 策略会删除同名目录再 clone/setup，
`worktree` 策略会清理 stale worktree registration 和目录后重新创建 worktree。因此未提交或未推送的本地进度不应只保存在 issue workspace 中。

`hooks.after_create` / `hooks.before_remove` 仍然可用。`project.repository_url` 和
source strategy 会先完成 source preparation，`project.setup_commands` 再完成 setup，随后
`hooks.after_create` 作为附加自定义命令执行。
hooks 和 setup commands 都会在 worker 机器上执行，保存前应确认命令安全。

Web UI 不提供独立的 workflow/routing 编辑 tab；路由始终来自 code-owned policy。当前
`/settings/agents` 与 `/settings/runtime` 仍展示 instance-owned 字段，但普通 project save 携带这些
字段会返回 typed rejection，不会修改 singleton；显式 `/settings/import` 才会把 combined package
拆分保存。`/settings/projects` 只保存 project-owned tracker/repository/source 字段，并始终列出全部
project。`profiles.yml` 的 `base_prompt` 导入后保存在 instance singleton，供所有 project 共用。

`codex.approval_policy` 是 Codex app-server 协议枚举，不再使用旧的结构化
`reject` map。当前支持值是 `untrusted`、`on-failure`、`on-request`、`granular` 和
`never`，默认值为 `never`。这个字段通过 `workflow.yml` 导入；如果
Codex 在启动握手阶段拒绝 `approvalPolicy`，错误会指向该设置项。

`codex.thread_sandbox` 和 `codex.turn_sandbox_policy` 是两个不同设置。前者用于 Codex
thread 启动，后者会作为每次 `turn/start` 的 `sandboxPolicy` 发送，实际影响 agent turn
是否能做网络操作，例如 `git push` 或 fetch。需要让 agent turn 访问网络时，在
在 `workflow.yml` 中把 Turn sandbox 设为 workspace write with network 或 danger full
access；保留未来 Codex sandbox 形状时使用 custom JSON。

当前默认 Linear 状态流是：

```text
Backlog
  -> Refining
  -> Needs Refinement Review
  -> Ready
  -> In Progress
  -> Ready to Merge
  -> Done
```

其中只有 `Todo`、`Ready`、`In Progress` 是可调度状态，会放进 `tracker.active_states` 并通过
`workflow.states.<state>.profile` 路由。`Needs Refinement Review` 和 `Ready to Merge` 是人工等待
状态，不进入 active states，也没有普通 executable route；成功 handoff 后仅允许独立、持久化且
只读的 PR review job。`Done` 是唯一成功终态；`Canceled`、
`Cancelled` 和 `Duplicate` 是取消终态。

实现完成不是普通 Codex turn exit。Codex 完成 validation、commit、push 精确 Linear
`branchName` 后，必须提交 final comment/result/references 并显式请求 `Ready to Merge`。Symphony
随后 Codex 调用受限 `create_pull_request`；Symphony backend 校验 repository/default/head，复用或创建
open GitHub PR。Codex 记录返回的 PR URL，最后才更新 Linear。
GitHub/PR/auth 失败会让 issue 保持 `In Progress`。人要求修改时使用
`Ready to Merge -> In Progress`；Codex 更新同一 branch/PR，再次验证并请求 handoff。初始 PR
正文由 Codex 按 [PR body contract](pull-request-body.md) 提交；已有
open PR 的人工正文不会被覆盖。人 merge PR
后，由 Linear GitHub automation 把 issue 移到 `Done`。
control plane 会在常规 reconciliation 中检查该精确 open PR；仅 GitHub 明确返回
`CONFLICTING`/`dirty` 时持久化 blocking decision 并执行 `Ready to Merge -> Blocked`。
`unknown`、behind、CI、review 或查询失败不会触发持久阻塞，也不会启动 Codex 或 worker。

Codex 与 Linear 的交互默认只暴露 `linear_task_read` 和 `linear_task_update`。Codex 不需要、
也不应拿到 Linear API Key 或 raw GraphQL；Symphony 后端负责持有凭据，并按 workflow profile
限制可更新字段和可流转状态。每次状态动作前都应先读取 task detail 和 comments，因为人工打回
通常通过评论说明新的要求。

### PR-first 安全 rollout 顺序

对每个 enabled project 和涉及的 Linear team，按下面顺序切换；不要只编辑 checked-in YAML：

1. 在每个 Linear team 配置 PR merged automation，把 linked issue 移到 `Done`；同时确认任何
   PR-open automation 不会在 Symphony handoff 后覆盖 `Ready to Merge`。
2. 让实际 Symphony runtime user 能使用已认证的 `gh`，或提供 `GH_TOKEN` / `GITHUB_TOKEN` 给
   REST fallback。使用 SSH execution 时，worker 还必须保留 branch-push auth。
3. 部署新代码，创建并校验 installation singleton，再为每个 enabled project 创建、校验、应用
   tracker/repository workflow slice。`workflow.yml` / `profiles.yml` 只是 package artifact，编辑它们
   不会修改运行时。
4. 手工处理仍处于退休状态 `In Review`、`Merging`、`Merged` 的运行中 issue，并确认没有 live
   issue 依赖旧 route。
5. live issue 清理完成后，才在每个相关 Linear team archive `In Review`、`Merging`、`Merged`。

只有所有相关 team 都启用 merged-to-`Done` automation，并在 live cleanup 后完成退休 state
archive，rollout 才算 operationally closed。

## 8. 启动 Symphony

只启动编排服务，不开 dashboard：

```bash
mise exec -- ./bin/symphony
```

启动 Web dashboard，例如监听 4000 端口：

```bash
mise exec -- ./bin/symphony \
  --port 4000
```

然后打开：

```text
http://127.0.0.1:4000/
```

如果启用了认证，先访问 `/login` 登录。

运行时配置来源是 PostgreSQL instance singleton 与 project workflow slice 的组合。`workflow.yml` 和 `profiles.yml` 是导入、
导出的 split package 文件，不再作为 CLI 启动参数，也不会在启动时自动导入。

### dashboard-first 数据库模式启动

如果你希望从数据库或 UI 管理 workflow，直接传 `--port`：

```bash
mise exec -- ./bin/symphony \
  --port 4000
```

此时规则是：

- `app_settings["instance_workflow"]` 是 runtime/profile 持久化权威；每个项目 workflow 只保存 tracker/source 属性。启动时组合并原子发布所有 enabled project 的完整 snapshot，日常读取不访问数据库。
- `Default` 项目只在 projects 表为空时作为 disabled 首启占位自动创建，且未配置仓库地址的占位记录不参与运行时派发。无显式 project context 时优先选择已配置的 Default；没有可用 Default 时仅在恰好一个 enabled workflow 存在时选择它。
- singleton 或 enabled project workflow 任一缺失时系统进入 setup-required；legacy full project row 不作为 singleton fallback。
- setup-required 状态不会监听 Linear 或调度 agent；先访问 `/settings/import`，导入并保存两个 scope。
- 不带 `--port` 时也使用同一个 PostgreSQL workflow source，只是不启动 Web dashboard。

## 9. 常用页面

启动 dashboard 后可访问：

```text
/             当前运行状态 dashboard
/runs         持久化 run 历史（支持按 project 过滤）
/workers      worker、task、lease 状态；集中式部署下可为空
/settings     Settings 入口，默认打开 Projects tab
/settings/projects 多 project 配置；每个 project 有自己的 Linear slug、repo URL、default branch；也提供 Linear discovery 辅助复制 project slug 和 workflow state 名称
/settings/import workflow package 导入（顶部 project 选择器限定到指定 project）
/settings/agents agent profile、base prompt、profile prompt、allowed updates 配置（project 选择器限定）
/settings/runtime runtime 摘要与 Codex model/reasoning effort selector（project 选择器限定）
/diagnostics/linear Linear API、project、workflow states 和候选 issue 诊断
/api/v1/state JSON 状态 API
/api/v1/:issue_identifier 当前 live 状态；inactive issue 会回退到持久化状态和最近结果
/api/v1/runs?issue_identifier=SYM-3 有界、倒序的 run 与 event timeline
```

## 10. 执行模式

当前默认执行模式仍是集中式：

```bash
export SYMPHONY_EXECUTION_MODE=centralized
```

集中式模式下，Phoenix Panel 负责执行，不需要注册外部 worker。如果 active workflow 配了
`worker.ssh_hosts`，集中式执行会在这些 SSH host 上准备 workspace、运行 hooks，并启动
`codex app-server`；否则就在本机运行。

worker 模式已经接入当前 orchestrator：

```bash
export SYMPHONY_EXECUTION_MODE=worker
```

此模式下，orchestrator 不直接启动 Codex，而是把 issue 持久化为 worker task，等待外部
worker 通过 `/api/worker/v1/*` 注册、claim、heartbeat 和上报事件。当前仓库实现的是 Panel
侧 HTTP/JSON 协议和 dashboard；生产级外部 worker 仍由独立进程/仓库提供。

worker API 需要 registration token：

```bash
export SYMPHONY_WORKER_REGISTRATION_TOKEN="replace-this-worker-token"
```

## 11. 热更新

Symphony 当前支持 Settings / workflow 配置热更新：保存 singleton 或 project slice 后，
持久化边界会在报告成功前重新组合并原子发布全部 enabled projects 的完整 snapshot，不需要重启服务。外部 activation 由单飞后台刷新检测；
PostgreSQL 刷新失败时，读取继续使用 last-known-good snapshot。代码级热更新和生产 OTP release hot upgrade 不是当前已支持的部署能力。

详细说明见 [Symphony 热更新说明](hot_update.zh-CN.md)。

## 12. 开发和验证命令

格式检查：

```bash
mise exec -- mix format --check-formatted
```

测试：

```bash
mise exec -- mix test
```

Lint：

```bash
mise exec -- mix lint
```

构建：

```bash
mise exec -- mix build
```

完整检查：

```bash
mise exec -- make all
```

默认单元测试不访问数据库。显式 PostgreSQL 集成 smoke 只能指向一次性空数据库；它会为 legacy
workflow 收敛的五个分支分别重建 migration 前 schema 并只向前迁移，验证已应用版本 no-op，随后
导入 SQLite fixture、验证关系，并发写入 200 条 event，然后验证数据库仍可读写：

```bash
export DATABASE_URL="postgresql://symphony:password@127.0.0.1:5432/symphony_smoke"
mise exec -- make pg-smoke
```

真实外部端到端测试会创建 Linear 资源并启动真实 Codex session，谨慎使用：

```bash
export LINEAR_API_KEY="..."
mise exec -- env SYMPHONY_RUN_LIVE_E2E=1 mix test --only live_e2e
```

这套 live E2E 目前保留为手动能力，也可以通过 `scripts/e2e.sh` 运行；它没有接入 CI workflow。

## 13. 常见问题

### 找不到 Elixir 或 Erlang

确认已执行：

```bash
mise trust
mise install
mise exec -- elixir --version
```

### PostgreSQL 连接或表不可用

确认 `DATABASE_URL` 可连接，再执行 migration：

```bash
psql "$DATABASE_URL" -c 'select 1'
mise exec -- mix symphony.migrate
```

### Dashboard 无法访问

确认启动时传了 `--port`，并且没有被认证重定向挡住：

```bash
mise exec -- ./bin/symphony \
  --port 4000
```

`--database-path` 和 `SYMPHONY_DATABASE_PATH` 已移除；运行时只接受 `DATABASE_URL`。

### Linear 拉不到 issue

检查：

- `LINEAR_API_KEY` 是否设置
- active workflow 里的 `tracker.project_slug` 是否正确
- issue 状态是否在 `tracker.active_states` 中
- Linear token 是否有权限读取对应 project

如果不确定 Linear project slug 或 workflow state 名称，先打开 Settings，点击
`Fetch Linear configuration` 获取只读 Linear discovery 结果；Projects tab 会展示结果，方便复制
候选值。保存 Settings 后，再打开 `/diagnostics/linear` 查看 token、project slug、
workflow source、configured states 和候选 issue 查询结果。
