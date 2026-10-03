---
title: Workspace Source Layout 设计
genre: design
domain: [workspace]
status: current
language: zh-CN
updated: 2026-10-03
design_status: landed
---

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

instance workflow singleton 应定义并保存：

- initialize timeout
- lifecycle hooks
- hook timeout
- clone strategy 使用的 workspace root
- repository base root
- worktree base root
- Codex sandbox policy 和 allowed roots

这些字段没有 per-project override。Project persistence/export 携带 instance 字段或 non-blank legacy
hook override 时返回 typed rejection；既有 project hook columns 保留在物理 schema 中但运行时忽略。

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

## Workspace root 有效性门禁

`WorkspacePreflight` 拥有 Panel-local `workspace.root` 的可访问、可创建和可写判定。所有返回错误中的
`path` 都先经过 `Path.expand/1`：

- 既有目录必须能在目录内创建并删除一个唯一临时子目录；探针失败返回 `:not_writable`，并保留底层
  reason。
- 缺失 root 不会被门禁创建。门禁向上查找最近的既有目录，并在该目录执行同一写探针；探针成功表示
  root 可创建，失败返回 `:not_creatable`。
- 既有非目录、路径查询返回 `:enotdir`，或最近既有祖先不是目录时返回 `:not_creatable`。
- 其它路径元数据读取失败返回 `:unreadable`。错误保留底层 reason，供 Settings 展示可操作原因。

Runtime / Agents 的正常 Save 在 `WorkflowForm.to_instance_scope/1` 成功后、change detection 和
persistence 之前调用 `WorkspacePreflight.check(:settings_save, root: ...)`。Settings / Import 的确认
路径在 scope 解析后、写入 instance singleton 或原子写入 Instance + Project 之前调用同一门禁。无效
root 因此不能进入 unchanged 或 saved 分支，也不能产生任一 scope 写入；Settings draft 保持 dirty，
Import stage 保留供修正，提示指向 `Settings / Import: workspace.root`，Compose 部署建议使用
`/data/workspaces`。缺失但最近既有祖先可写的 root 合法。

`WorkspacePreflight.check(:pre_listen, settings: ...)` 冻结了 listening 接线复用的契约：先执行相同
root 判定，再调用 `WorkspaceDiskGuard`。空间拒绝沿用 `:low_disk_space` 和
`:disk_space_unavailable`，并把 guard reason map 原样放入 `reason`。`workspace.min_free_bytes <= 0`
只跳过空间读取，不能跳过 root 判定。两个 listening 入口尚未消费该契约；运行时接线属于 SYM-156，
因此本设计当前只改变 Runtime / Agents Save 与 Settings / Import 确认。

测试可按调用传入 `:path_info_fun`、`:write_probe_fun` 和 `:free_bytes_fun`。前两者只替换单次 root
判定的 `File.stat/1` 与写探针；后者只透传给 `WorkspaceDiskGuard.check/2`。这些 seam 用于稳定覆盖
`:eacces`、`:erofs`、低空间和空间读取失败，不是 Application 配置、共享状态或第二套 filesystem
模型。生产调用不传 seam。

## 启动前磁盘检查

`WorkspaceDiskGuard` 是本地 agent 启动前的准入检查。Orchestrator 在本地
agent spawn / workspace preparation 之前调用它；远端 worker 的磁盘状况不由该模块探测。

检查输入来自 instance singleton 与 project slice 组合后的 runtime snapshot。`workspace.min_free_bytes` 是最低可用空间阈值，
未配置时默认为 `1_073_741_824` bytes（1 GiB）；值小于或等于 `0` 时跳过磁盘检查并返回
`free_bytes: :unchecked`。阈值只控制准入，不触发清理或其它磁盘修改。

检查范围是去重后的三个 root：

- `workspace.root`
- `SourcePreparation.repository_base_root(settings)`
- `SourcePreparation.worktree_base_root(settings)`

每个 root 先展开为绝对路径；如果路径还不存在，检查最近的既有祖先目录。实际可用空间通过
`df -Pk <existing_ancestor>` 读取并按 KiB 转 bytes。所有 root 都达到阈值时，启动继续。任一 root
低于阈值时返回 typed reason `:low_disk_space`，包含 root、free bytes、min bytes 和可操作的
Settings 字段 `Settings / Import: workspace.min_free_bytes`。`df` 失败或输出不可解析时返回
`:disk_space_unavailable`，包含失败 detail 和相同 Settings 字段。

Orchestrator 把任一拒绝或检查异常视为本次启动拒绝：它记录 `run.blocked`，在 blocked entry 的
session history 写入 `workspace_disk_guard.blocked`，并保留 typed reason 供状态/API 展示。该路径不创建、
删除或修改 workspace。

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

## 破坏性清理护栏

`WorkspaceCleanupPolicy` 是 `Workspace` 执行 destructive cleanup 前的共享准入策略。调用方包括本地
workspace 删除、远端 workspace 删除、以及 worktree strategy 下的 `git worktree remove --force`
前置判断。policy 只回答目标路径是否允许删除；它不派生 workspace 路径，不执行 `rm_rf`、远端命令或
`git worktree` 命令。

本地删除使用 `validate_local_delete(path, roots: roots, protected_paths: protected_paths)`：

- 非 binary path 拒绝为 `:invalid_path`；canonicalization 失败拒绝为
  `{:path_canonicalize_failed, path, reason}`。
- delete path、roots、protected paths 都先展开并通过 `PathSafety.canonicalize/1` 解析真实路径，
  因此 symlink 逃逸会被识别为 root 外路径。
- delete path 必须是某个 root 的 strict descendant；root 本身拒绝为
  `{:cleanup_path_equals_root, root}`，root 外路径拒绝为
  `{:cleanup_path_outside_roots, delete_path, roots}`。
- delete path 等于 protected path 时拒绝为 `{:cleanup_path_equals_protected_path, delete_path}`。
  delete path 是 protected path 的父目录、会把 protected path 一并删除时，拒绝为
  `{:cleanup_path_contains_protected_path, delete_path, protected_path}`。

远端删除使用 `validate_remote_delete(path, root)`，只能在控制面做字符串级边界判断。它拒绝空 path/root、
包含换行、回车或 NUL 的 path、root 本身、以及 root 外路径；允许值必须是规范化后的 strict
descendant。远端 policy 不在控制面执行 filesystem canonicalization，也不宣称与本地 symlink/protected-path
防护等价。

## 不做什么

- 不把 clone/worktree 命令塞回 hooks。
- 不让用户填写每个 issue 的完整 worktree 路径。
- 不让 `/tmp` 默认 base repo 和 `~/.symphony` 默认 worktree 隐式混用。
- 不为了旧字段名保留长期兼容语义；alpha 阶段应直接迁移到清晰字段。
- 不把 repository URL、default branch、checkout depth 放回 workflow 页面。
