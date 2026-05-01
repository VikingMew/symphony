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

## 7. 配置 WORKFLOW.md

默认 workflow 文件是：

```text
elixir/WORKFLOW.md
```

最少需要确认这些字段：

```yaml
tracker:
  kind: linear
  project_slug: "你的 Linear project slug"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
codex:
  command: codex app-server
```

`WORKFLOW.md` 的 YAML front matter 和 Markdown prompt 都是 Symphony 的 workflow contract。后续可以通过 Web UI 的 `/workflows` 页面管理 workflow versions。

## 8. 启动 Symphony

只启动编排服务，不开 dashboard：

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

启动 Web dashboard，例如监听 4000 端口：

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

然后打开：

```text
http://127.0.0.1:4000/
```

如果启用了认证，先访问 `/login` 登录。

## 9. 常用页面

启动 dashboard 后可访问：

```text
/             当前运行状态 dashboard
/projects     项目列表
/runs         持久化 run 历史
/workflows    WORKFLOW.md raw 编辑和版本历史
/settings     tracker/config 摘要
/api/v1/state JSON 状态 API
```

## 10. 开发和验证命令

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

## 11. 常见问题

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

确认启动时传了 `--port`：

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

### Linear 拉不到 issue

检查：

- `LINEAR_API_KEY` 是否设置
- `WORKFLOW.md` 里的 `tracker.project_slug` 是否正确
- issue 状态是否在 `tracker.active_states` 中
- Linear token 是否有权限读取对应 project

