# Symphony 用户运行指南

这份指南说明如何在 macOS 和 Ubuntu 上安装依赖、配置环境变量、初始化 SQLite，并启动 Symphony Web 服务。

## 1. 前置要求

Symphony Elixir 需要：

- Git
- mise
- Erlang / Elixir，通过 `mise install` 安装
- Linear API Key
- Codex CLI，且支持 `codex app-server`
- SQLite，本地持久化使用

项目声明的运行时版本在 `elixir/mise.toml`：

```toml
[tools]
erlang = "28"
elixir = "1.19.5-otp-28"
```

## 2. macOS 安装依赖

推荐使用 Homebrew：

```bash
brew install git mise sqlite
```

初始化 mise shell：

```bash
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
```

验证：

```bash
mise --version
sqlite3 --version
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
sudo apt install -y git curl build-essential autoconf m4 libncurses5-dev libssl-dev libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils sqlite3
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
sqlite3 --version
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

可选：配置 SQLite 数据库位置。

```bash
export SYMPHONY_DATABASE_PATH="$PWD/symphony.db"
```

可选：启用 Web UI 登录认证。

```bash
export SYMPHONY_AUTH_ENABLED=true
export SYMPHONY_ADMIN_USERNAME=admin
export SYMPHONY_ADMIN_PASSWORD="请换成你自己的密码"
```

如果不设置 `SYMPHONY_AUTH_ENABLED=true`，认证默认关闭，适合本地临时开发，不建议用于共享机器或可被其他人访问的网络环境。

## 6. 初始化 SQLite

首次运行前执行 migration：

```bash
mise exec -- mix ecto.migrate
```

如果需要重置本地数据：

```bash
rm -f symphony.db symphony.db-shm symphony.db-wal
mise exec -- mix ecto.migrate
```

## 7. 配置 workflow

运行时配置来源是 SQLite active workflow version。空数据库会进入 setup-required 状态，不会开始
监听 Linear 或调度 agent；先在 `/settings/workflow` 和 `/settings/agents` 创建第一版 active
workflow。

`workflow.yml` 和 `profiles.yml` 是 split workflow package 的导入/导出格式，不是启动参数，也不
是运行时 fallback。这个 package 由两个文件组成：

```text
elixir/workflow.yml
elixir/profiles.yml
```

`workflow.yml` 里最少需要确认这些字段：

```yaml
tracker:
  kind: linear
  project_slug: "你的 Linear project slug"
workspace:
  root: ~/code/symphony-workspaces
project:
  repository_url: "git@github.com:your-org/your-repo.git"
  default_branch: "main"
  checkout_depth: 1
  setup_commands: []
  cleanup_commands: []
codex:
  command: codex app-server
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
  human_review_states: ["Needs Refinement Review", "Needs Implementation Review"]
  tool_policy:
    linear:
      exposed_tools: ["linear_task_read", "linear_task_update"]
      raw_graphql: false
```

`profiles.yml` 里配置共享 base prompt 和 agent profile：

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

`workspace.root` 是 Symphony 管理 issue workspace 的根目录，不是你的项目仓库目录。Symphony
会在这个目录下为每个 Linear issue 创建子目录，然后把 `project.repository_url` 指向的仓库
clone 到该 issue workspace 中。`project.repository_url` 是运行必填项；缺失或为空时
workflow 配置校验失败，Symphony 不会拉取 Linear 候选任务或启动 agent。

Rust 项目可以这样写 bootstrap：

```yaml
project:
  repository_url: "git@github.com:your-org/your-rust-repo.git"
  default_branch: "main"
  checkout_depth: 1
  setup_commands:
    - cargo fetch
  cleanup_commands: []
```

Elixir 项目才应该使用 Elixir 专属命令，例如：

```yaml
project:
  repository_url: "git@github.com:your-org/your-elixir-repo.git"
  setup_commands:
    - mise trust
    - mise exec -- mix deps.get
  cleanup_commands:
    - mix workspace.before_remove || true
```

每次 agent start 都会重新创建该 issue workspace；如果同名目录已经存在，Symphony 会先删除它，再重新 clone/setup。
因此未提交或未推送的本地进度不应只保存在 issue workspace 中。

`hooks.after_create` / `hooks.before_remove` 仍然可用。`project.repository_url` 和
`project.setup_commands` 会先完成 checkout/setup，随后 `hooks.after_create` 作为附加自定义命令执行。
hooks 和 setup commands 都会在 worker 机器上执行，保存前应确认命令安全。

Web UI 的 `/settings/workflow` tab 管理 workflow/routing，`/settings/agents` tab 管理 base
prompt 和 profiles。后续导入/导出 split package 时，`profiles.yml` 的 `base_prompt` 是共享
prompt 来源。

当前默认 Linear 状态流是：

```text
Backlog
  -> Refining
  -> Needs Refinement Review
  -> Ready
  -> In Progress
  -> Needs Implementation Review
  -> Ready to Merge
  -> Merging
  -> Done
```

其中 `Refining`、`Ready`、`In Progress`、`Ready to Merge`、`Merging` 是可调度状态，会放进
`tracker.active_states`，并通过 `workflow.states.<state>.profile` 指定对应 profile。`Needs
Refinement Review` 和 `Needs Implementation Review` 是人工确认状态，不应放进 active states。
`Done`、`Canceled` 和 `Duplicate` 是终态。

Codex 与 Linear 的交互默认只暴露 `linear_task_read` 和 `linear_task_update`。Codex 不需要、
也不应拿到 Linear API Key 或 raw GraphQL；Symphony 后端负责持有凭据，并按 workflow profile
限制可更新字段和可流转状态。每次状态动作前都应先读取 task detail 和 comments，因为人工打回
通常通过评论说明新的要求。

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

运行时配置来源是 SQLite active workflow version。`workflow.yml` 和 `profiles.yml` 是导入、
导出的 split package 文件，不再作为 CLI 启动参数，也不会在启动时自动导入。

### dashboard-first 数据库模式启动

如果你希望从数据库或 UI 管理 workflow，直接传 `--port`：

```bash
mise exec -- ./bin/symphony \
  --port 4000
```

此时规则是：

- 运行时配置来源是 SQLite active workflow version。
- 如果 SQLite 中还没有 active workflow version，系统进入 setup-required。
- setup-required 状态不会监听 Linear 或调度 agent；先访问 `/settings/workflow`，用结构化表单创建第一个 workflow。
- 不带 `--port` 时也使用 SQLite workflow source，只是不启动 Web dashboard。

## 9. 常用页面

启动 dashboard 后可访问：

```text
/             当前运行状态 dashboard
/runs         持久化 run 历史
/workers      worker、task、lease 状态；集中式部署下可为空
/settings     Settings 入口，默认打开 Projects tab
/settings/projects 多 project 配置；每个 project 有自己的 Linear slug、repo URL、default branch
/settings/workflow workflow/routing/runtime 共享结构化配置和版本历史
/settings/agents agent profile、base prompt、profile prompt、allowed updates 配置
/settings/runtime tracker/config 摘要
/diagnostics/linear Linear API、project、workflow states 和候选 issue 诊断
/api/v1/state JSON 状态 API
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

## 11. 开发和验证命令

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

真实外部端到端测试会创建 Linear 资源并启动真实 Codex session，谨慎使用：

```bash
export LINEAR_API_KEY="..."
mise exec -- make e2e
```

## 12. 常见问题

### 找不到 Elixir 或 Erlang

确认已执行：

```bash
mise trust
mise install
mise exec -- elixir --version
```

### SQLite 表不存在

执行 migration：

```bash
mise exec -- mix ecto.migrate
```

### Dashboard 无法访问

确认启动时传了 `--port`，并且没有被认证重定向挡住：

```bash
mise exec -- ./bin/symphony \
  --port 4000
```

如果需要指定数据库文件，使用 `--database-path`：

```bash
mise exec -- ./bin/symphony \
  --port 4000 \
  --database-path ./symphony.db
```

### Linear 拉不到 issue

检查：

- `LINEAR_API_KEY` 是否设置
- active workflow 里的 `tracker.project_slug` 是否正确
- issue 状态是否在 `tracker.active_states` 中
- Linear token 是否有权限读取对应 project

也可以打开 `/diagnostics/linear` 查看 token、project slug、workflow source、configured
states 和候选 issue 查询结果。
