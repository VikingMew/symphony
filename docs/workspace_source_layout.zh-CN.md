# Workspace Source Layout 设计

本文维护 Symphony 在本地准备代码目录时的长期设计。它只讨论 repository cache、issue worktree、clone workspace 和 sandbox root 的路径模型，不承载通用产品方向。

## 目标

Project source strategy 需要把几个概念拆清楚：

- repository base root：集中保存每个项目的基础仓库缓存。
- worktree base root：集中保存每个 issue 的实际 git worktree。
- clone workspace root：`source_strategy: clone` 时为每个 issue 直接 clone 的目录根。
- sandbox allowed roots：Codex 运行时允许访问的目录集合，必须包含最终 agent cwd。

当前容易混淆的是：`worktree_base_path` 既可能被理解成一个完整 repo path，也可能被理解成存放多个 repo 的 root；`worktree_root` 又可能和 workflow 的 `workspace.root` 发生冲突。长期设计要求 UI 和代码都不要让用户同时填写“完整路径”和“根路径”而不知道最终拼接规则。

## 路径规则

Worktree strategy 应使用两个共享 base root：

```text
repository_base_root / repo_cache_name
worktree_base_root   / issue_identifier
```

其中：

- `repository_base_root` 是目录 root，不是某一个 repo 本身。
- `repo_cache_name` 由 project slug、repository URL 或 default branch 派生，必须稳定、可读、避免路径穿越。
- `worktree_base_root` 是目录 root，不是某一个 issue worktree 本身。
- `issue_identifier` 来自 Linear identifier，例如 `CCR-5`，必须规范化并防止路径穿越。
- 最终 Codex cwd 是 `worktree_base_root / issue_identifier`。
- 最终 Codex cwd 必须在 sandbox allowed roots 内，否则运行前应报配置错误并指向对应 Settings 字段。

Clone strategy 应使用：

```text
clone_workspace_root / issue_identifier
```

其中 `clone_workspace_root` 可以继续来自 workflow workspace root。它也必须参与同一套 sandbox allowed roots 校验。

## 推荐默认值

本地默认路径应聚合在同一个用户可见目录下，避免 `/tmp`、`~/.symphony/repository`、`~/.symphony/worktree` 混用：

```text
~/.symphony/workspaces/
├── repositories/
│   └── <repo_cache_name>/
└── worktrees/
    └── <issue_identifier>/
```

如果用户显式配置：

```text
repository_base_root = ~/.symphony/workspaces/repositories
worktree_base_root   = ~/.symphony/workspaces/worktrees
```

那么项目 `ccr` 的 issue `CCR-5` 应派生为：

```text
base repo:  ~/.symphony/workspaces/repositories/ccr-<hash>
worktree:   ~/.symphony/workspaces/worktrees/CCR-5
```

不要再要求用户手写完整的 `.../CCR-5` 路径，也不要把 worktree base repo 放在 `/tmp` 而把 issue worktree 放在 `~/.symphony`，除非 sandbox allowed roots 同时覆盖两者且 UI 明确展示最终路径。

## UI 责任

Project Settings 应展示并保存 project-specific source 信息：

- repository URL
- default branch
- checkout depth
- source strategy
- fetch before worktree
- clean stale worktree
- setup / cleanup commands

Workflow Settings 应继续展示并保存：

- initialize timeout
- lifecycle hooks
- hook timeout
- clone strategy 使用的 workspace root
- repository base root
- worktree base root
- Codex sandbox policy 和 allowed roots

UI 必须展示最终派生路径预览：

- base repo path
- issue worktree path 示例
- 当前 sandbox allowed roots 是否覆盖最终 cwd

## 校验

字段级校验：

- base root 不能为空。
- base root 可以展开 `~`。
- base root 不能包含 issue identifier 占位拼接后的路径穿越。
- timeout、depth 等数值字段必须可解析。

配置级校验：

- worktree strategy 下，最终 issue worktree path 必须在 sandbox allowed roots 内。
- base repo path 和 issue worktree path 不应相同。
- repository base root 和 worktree base root 可以同属一个上级目录，但不能互相嵌套到会导致 `git worktree` 管理混乱的路径。
- stale worktree cleanup 只能清理由 Symphony 派生出的 issue worktree path，不清理用户任意目录。

错误提示必须指向用户能修改的字段。例如：

```text
Worktree path is outside allowed sandbox roots.
Set Settings / Workflow / Workspace / Worktree base root under an allowed root,
or add that root to Settings / Workflow / Codex / Sandbox allowed roots.
```

## 运行时顺序

Worktree strategy 的顺序是：

1. 解析 project source settings。
2. 派生 `repo_cache_name` 和 `issue_identifier`。
3. 计算 base repo path 和 issue worktree path。
4. 校验两个路径不逃逸 base root。
5. clone repository base repo；如果 base repo 已存在且启用 fetch before worktree，则 fetch `origin/<default_branch>`。
6. 把托管 base repo 的本地 `default_branch` 更新到刚 fetch 到的 remote ref。
7. 清理 stale worktree registration 和 issue worktree path。
8. 从更新后的 base branch 创建 issue worktree。
9. 运行 project setup commands。
10. 运行 lifecycle `after_create`。
11. 启动 Codex，cwd 为 issue worktree path。

`repository_base_root` 只用于 base repo cache，是共享运行配置，不是 project 字段。Codex 不应以 base repo path 作为 cwd。`worktree_base_root` 只用于 issue worktree，也是共享运行配置。git clone/fetch 进度、worktree add 进度和 hook 输出应继续写入 session history 的 system progress。

## 不做什么

- 不把 clone/worktree 命令塞回 hooks。
- 不让用户填写每个 issue 的完整 worktree 路径。
- 不让 `/tmp` 默认 base repo 和 `~/.symphony` 默认 worktree 隐式混用。
- 不为了旧字段名保留长期兼容语义；alpha 阶段应直接迁移到清晰字段。
- 不把 repository URL、default branch、checkout depth 放回 workflow 页面。
