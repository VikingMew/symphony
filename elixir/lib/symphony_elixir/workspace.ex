defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, PersistenceProvider, WorkspaceCleanupPolicy}
  alias SymphonyElixir.Workspace.{HookRunner, Remote, SourcePreparation}

  @hook_recent_output_bytes 4_096
  @hook_event_output_bytes 2_048
  @hook_command_preview_bytes 512

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      emit_system_progress(opts, issue_context, %{
        phase: "workspace_preparing",
        operation: "workspace_prepare",
        status: "started",
        detail: "Preparing workspace",
        worker_host: worker_host_for_log(worker_host)
      })

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_commands(workspace, issue_context, created?, worker_host, opts) do
        emit_system_progress(opts, issue_context, %{
          phase: "workspace_preparing",
          operation: "workspace_prepare",
          status: "completed",
          detail: "Workspace ready",
          workspace: workspace,
          worker_host: worker_host_for_log(worker_host)
        })

        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    create_workspace(workspace)
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    with :ok <- WorkspaceCleanupPolicy.validate_remote_delete(workspace, Config.settings!().workspace.root) do
      do_ensure_remote_workspace(workspace, worker_host)
    end
  end

  defp do_ensure_remote_workspace(workspace, worker_host) do
    Remote.ensure_workspace(worker_host, workspace, Config.settings!().hooks.timeout_ms)
  end

  defp create_workspace(workspace) do
    with :ok <- validate_cleanup_delete(workspace, [workspace_root()]) do
      File.rm_rf!(workspace)
      File.mkdir_p!(workspace)
      {:ok, workspace, true}
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        with :ok <- validate_workspace_path(workspace, nil),
             :ok <- validate_cleanup_delete(workspace, [workspace_root()]) do
          maybe_run_before_remove_hook(workspace, nil)
          maybe_remove_project_worktree(workspace)
          File.rm_rf(workspace)
        else
          {:error, reason} -> {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    case WorkspaceCleanupPolicy.validate_remote_delete(workspace, Config.settings!().workspace.root) do
      :ok ->
        maybe_run_before_remove_hook(workspace, worker_host)

        Remote.remove_workspace(worker_host, workspace, Config.settings!().hooks.timeout_ms)

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, nil, opts)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, nil, opts)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp workspace_root do
    settings = Config.settings!()

    case settings.project.source_strategy do
      "worktree" -> SourcePreparation.worktree_base_root(settings)
      _clone -> settings.workspace.root
    end
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_commands(workspace, issue_context, created?, worker_host, opts) do
    case created? do
      true ->
        run_after_create_commands(workspace, issue_context, worker_host, opts)

      false ->
        :ok
    end
  end

  defp run_after_create_commands(workspace, issue_context, worker_host, opts) do
    hooks = Config.settings!().hooks

    with :ok <- run_project_bootstrap(workspace, issue_context, worker_host, opts) do
      run_optional_hook(hooks.after_create, workspace, issue_context, "after_create", worker_host, nil, opts)
    end
  end

  defp run_project_bootstrap(workspace, issue_context, nil, opts) do
    settings = Config.settings!()

    case settings.project.source_strategy do
      "worktree" ->
        with :ok <- prepare_worktree_source(settings, workspace, issue_context, opts) do
          run_optional_hook(
            Config.project_setup_commands(),
            workspace,
            issue_context,
            "project_bootstrap",
            nil,
            settings.workspace.initialize_timeout_ms,
            opts
          )
        end

      _clone ->
        run_optional_hook(
          Config.generated_project_bootstrap_commands(),
          workspace,
          issue_context,
          "project_bootstrap",
          nil,
          settings.workspace.initialize_timeout_ms,
          opts
        )
    end
  end

  defp run_project_bootstrap(workspace, issue_context, worker_host, opts) when is_binary(worker_host) do
    settings = Config.settings!()

    case settings.project.source_strategy do
      "worktree" ->
        {:error, {:unsupported_remote_source_strategy, "worktree", worker_host}}

      _clone ->
        run_optional_hook(
          Config.generated_project_bootstrap_commands(),
          workspace,
          issue_context,
          "project_bootstrap",
          worker_host,
          settings.workspace.initialize_timeout_ms,
          opts
        )
    end
  end

  defp run_optional_hook(command, workspace, issue_context, hook_name, worker_host, timeout_ms, opts) do
    command
    |> blank?()
    |> case do
      true -> :ok
      false -> run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_ms, opts)
    end
  end

  defp prepare_worktree_source(settings, workspace, issue_context, opts) do
    project = settings.project
    timeout_ms = settings.workspace.initialize_timeout_ms
    started_at = System.monotonic_time(:millisecond)
    base_path = repository_cache_path(settings)
    branch = SourcePreparation.worktree_branch(issue_context.issue_identifier)

    Logger.info("Preparing project worktree #{issue_log_context(issue_context)} base=#{base_path} workspace=#{workspace}")
    log_phase("workspace_bootstrap", :started, issue_context, workspace, nil)
    persist_phase_event("workspace_bootstrap", :started, issue_context, workspace, nil, started_at, %{source_strategy: "worktree"})

    emit_system_progress(opts, issue_context, %{
      phase: "workspace_bootstrap",
      operation: "worktree_prepare",
      status: "started",
      detail: "Preparing project worktree",
      workspace: workspace,
      base_path: base_path
    })

    result =
      with :ok <- ensure_worktree_base_repo(project, base_path, timeout_ms, opts, issue_context),
           :ok <- maybe_fetch_worktree_base(project, base_path, timeout_ms, opts, issue_context),
           :ok <- cleanup_stale_worktree(base_path, workspace, project, timeout_ms, opts, issue_context) do
        add_worktree(base_path, workspace, branch, project.default_branch, timeout_ms, opts, issue_context)
      end

    case result do
      :ok ->
        persist_phase_event("workspace_bootstrap", :completed, issue_context, workspace, nil, started_at, %{
          source_strategy: "worktree",
          base_path: base_path,
          branch: branch
        })

        emit_system_progress(opts, issue_context, %{
          phase: "workspace_bootstrap",
          operation: "worktree_prepare",
          status: "completed",
          detail: "Project worktree ready",
          workspace: workspace,
          base_path: base_path,
          branch: branch
        })

        :ok

      {:error, reason} ->
        persist_phase_event("workspace_bootstrap", :failed, issue_context, workspace, nil, started_at, %{
          source_strategy: "worktree",
          base_path: base_path,
          reason: inspect(reason)
        })

        emit_system_progress(opts, issue_context, %{
          phase: "workspace_bootstrap",
          operation: "worktree_prepare",
          status: "failed",
          detail: "Project worktree failed: #{inspect(reason, limit: 20, printable_limit: 500)}",
          workspace: workspace,
          base_path: base_path
        })

        {:error, reason}
    end
  end

  defp ensure_worktree_base_repo(project, base_path, timeout_ms, opts, issue_context) do
    cond do
      git_repo?(base_path) ->
        :ok

      blank?(project.repository_url) ->
        {:error, :missing_project_repository_url}

      File.exists?(base_path) and empty_directory_tree?(base_path) ->
        with :ok <- validate_cleanup_delete(base_path, [SourcePreparation.repository_base_root(Config.settings!())]) do
          File.rm_rf!(base_path)
          clone_worktree_base(project, base_path, timeout_ms, opts, issue_context)
        end

      File.exists?(base_path) and not empty_directory?(base_path) ->
        {:error, {:invalid_worktree_base_repo, base_path}}

      true ->
        clone_worktree_base(project, base_path, timeout_ms, opts, issue_context)
    end
  end

  defp clone_worktree_base(project, base_path, timeout_ms, opts, issue_context) do
    parent = Path.dirname(base_path)
    File.mkdir_p!(parent)

    emit_system_progress(opts, issue_context, %{
      phase: "workspace_bootstrap",
      operation: "git_clone",
      status: "started",
      detail: "Cloning base repository",
      base_path: base_path
    })

    args =
      ["clone", "--progress"]
      |> maybe_append_git_arg("--branch", project.default_branch)
      |> Kernel.++([project.repository_url, base_path])

    run_git(parent, args, timeout_ms, progress_callback(opts, issue_context, "workspace_bootstrap", "git_clone", "Cloning base repository"))
  end

  defp maybe_fetch_worktree_base(%{worktree_fetch: false}, _base_path, _timeout_ms, _opts, _issue_context), do: :ok

  defp maybe_fetch_worktree_base(project, base_path, timeout_ms, opts, issue_context) do
    branch = project.default_branch || "main"

    emit_system_progress(opts, issue_context, %{
      phase: "workspace_bootstrap",
      operation: "git_fetch",
      status: "started",
      detail: "Fetching base repository #{branch}",
      base_path: base_path,
      branch: branch,
      repository_url: project.repository_url
    })

    with :ok <-
           run_git(
             base_path,
             ["fetch", "origin", branch, "--prune"],
             timeout_ms,
             progress_callback(opts, issue_context, "workspace_bootstrap", "git_fetch", "Fetching base repository")
           ),
         :ok <- update_worktree_base_branch(base_path, branch, timeout_ms, opts, issue_context) do
      :ok
    else
      {:error, reason} -> {:error, {:worktree_source_sync_failed, project.repository_url, branch, reason}}
    end
  end

  defp update_worktree_base_branch(base_path, branch, timeout_ms, opts, issue_context) do
    emit_system_progress(opts, issue_context, %{
      phase: "workspace_bootstrap",
      operation: "git_update_base_branch",
      status: "started",
      detail: "Updating base branch #{branch}",
      base_path: base_path,
      branch: branch
    })

    with :ok <- run_git(base_path, ["rev-parse", "--verify", "refs/remotes/origin/#{branch}"], timeout_ms),
         :ok <- run_git(base_path, ["update-ref", "refs/heads/#{branch}", "refs/remotes/origin/#{branch}"], timeout_ms) do
      emit_system_progress(opts, issue_context, %{
        phase: "workspace_bootstrap",
        operation: "git_update_base_branch",
        status: "completed",
        detail: "Base branch #{branch} updated",
        base_path: base_path,
        branch: branch
      })

      :ok
    end
  end

  defp cleanup_stale_worktree(base_path, workspace, %{worktree_cleanup: false}, timeout_ms, opts, issue_context) do
    if File.exists?(workspace) do
      {:error, {:worktree_exists, workspace}}
    else
      run_git(base_path, ["worktree", "prune"], timeout_ms, progress_callback(opts, issue_context, "workspace_bootstrap", "worktree_prune", "Pruning stale worktrees"))
    end
  end

  defp cleanup_stale_worktree(base_path, workspace, _project, timeout_ms, opts, issue_context) do
    worktree_root = SourcePreparation.worktree_base_root(Config.settings!())

    with :ok <-
           validate_cleanup_delete(workspace, [worktree_root], protected_paths: [base_path]) do
      _ =
        run_git(
          base_path,
          ["worktree", "remove", "--force", workspace],
          timeout_ms,
          progress_callback(
            opts,
            issue_context,
            "workspace_bootstrap",
            "worktree_remove",
            "Removing stale worktree"
          )
        )

      _ =
        run_git(
          base_path,
          ["worktree", "prune"],
          timeout_ms,
          progress_callback(opts, issue_context, "workspace_bootstrap", "worktree_prune", "Pruning stale worktrees")
        )

      File.rm_rf!(workspace)
      File.mkdir_p!(Path.dirname(workspace))
      :ok
    end
  end

  defp add_worktree(base_path, workspace, branch, default_branch, timeout_ms, opts, issue_context) do
    ref = worktree_base_ref(base_path, default_branch, timeout_ms)

    emit_system_progress(opts, issue_context, %{
      phase: "workspace_bootstrap",
      operation: "worktree_add",
      status: "started",
      detail: "Creating project worktree",
      workspace: workspace,
      branch: branch
    })

    run_git(
      base_path,
      ["worktree", "add", "-B", branch, workspace, ref],
      timeout_ms,
      progress_callback(opts, issue_context, "workspace_bootstrap", "worktree_add", "Creating project worktree")
    )
  end

  defp worktree_base_ref(base_path, branch, timeout_ms) when is_binary(branch) and branch != "" do
    case run_git(base_path, ["rev-parse", "--verify", branch], timeout_ms) do
      :ok -> branch
      {:error, _reason} -> "origin/#{branch}"
    end
  end

  defp worktree_base_ref(_base_path, _branch, _timeout_ms), do: "HEAD"

  defp git_repo?(path) do
    File.dir?(path) and run_git(path, ["rev-parse", "--git-dir"]) == :ok
  end

  defp empty_directory?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp empty_directory_tree?(path) do
    File.dir?(path) and
      path
      |> File.ls!()
      |> Enum.all?(fn child ->
        child_path = Path.join(path, child)
        File.dir?(child_path) and empty_directory_tree?(child_path)
      end)
  rescue
    _error -> false
  end

  defp repository_cache_path(settings), do: SourcePreparation.repository_cache_path(settings)

  defp maybe_remove_project_worktree(workspace) do
    settings = Config.settings!()

    if settings.project.source_strategy == "worktree" do
      base_path = repository_cache_path(settings)
      worktree_root = SourcePreparation.worktree_base_root(settings)

      delete_allowed? =
        validate_cleanup_delete(workspace, [worktree_root], protected_paths: [base_path]) == :ok

      if git_repo?(base_path) and delete_allowed? do
        _ = run_git(base_path, ["worktree", "remove", "--force", workspace])
        _ = run_git(base_path, ["worktree", "prune"])
      end
    end

    :ok
  rescue
    _error -> :ok
  end

  defp validate_cleanup_delete(path, roots, opts \\ []) do
    protected_paths = Keyword.get(opts, :protected_paths, [])
    WorkspaceCleanupPolicy.validate_local_delete(path, roots: roots, protected_paths: protected_paths)
  end

  defp run_git(cwd, args) do
    executable = System.find_executable("git") || "git"

    case System.cmd(executable, args, cd: cwd, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_command_failed, args, status, sanitize_hook_output_for_log(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp run_git(cwd, args, nil), do: run_git(cwd, args)

  defp run_git(cwd, args, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    run_git(cwd, args, timeout_ms, fn _chunk, _recent_output -> :ok end)
  end

  defp run_git(cwd, args, timeout_ms, on_output) when is_integer(timeout_ms) and timeout_ms > 0 do
    executable = System.find_executable("git") || "git"
    command = SymphonyElixir.Shell.escape(executable) <> " " <> Enum.map_join(args, " ", &SymphonyElixir.Shell.escape/1)

    command
    |> run_local_hook_command(cwd, timeout_ms, on_output)
    |> case do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:git_command_failed, args, status, sanitize_hook_output_for_log(output)}}

      {:error, {:workspace_hook_timeout, "local_command", ^timeout_ms, details}} ->
        {:error, {:workspace_hook_timeout, "project_bootstrap", timeout_ms, details}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp maybe_append_git_arg(args, _flag, nil), do: args
  defp maybe_append_git_arg(args, _flag, ""), do: args
  defp maybe_append_git_arg(args, flag, value), do: args ++ [flag, value]

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove || Config.generated_before_remove_hook() do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove || Config.generated_before_remove_hook() do
      nil ->
        :ok

      command ->
        Remote.run_command(worker_host, Remote.before_remove_script(workspace, command), Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp blank?(value), do: SymphonyElixir.Text.blankish?(value)

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_override_ms \\ nil, opts \\ [])

  defp run_hook(command, workspace, issue_context, hook_name, nil, timeout_override_ms, opts) do
    timeout_ms = timeout_override_ms || Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)
    phase = phase_for_hook(hook_name)

    log_workspace_command_start(hook_name, issue_context, workspace, nil)
    log_phase(phase, :started, issue_context, workspace, nil)
    persist_phase_event(phase, :started, issue_context, workspace, nil, started_at, %{})
    persist_hook_event("workspace.hook_started", issue_context, hook_name, workspace, nil, command, started_at, %{})

    emit_system_progress(opts, issue_context, %{
      phase: phase,
      operation: "hook:#{hook_name}",
      status: "started",
      detail: "Running #{hook_name}",
      workspace: workspace,
      hook: hook_name
    })

    command
    |> run_local_hook_command(workspace, timeout_ms, fn chunk, recent_output ->
      persist_hook_output(issue_context, hook_name, workspace, nil, command, started_at, chunk, recent_output)

      emit_system_output(opts, issue_context, phase, "hook:#{hook_name}", "Running #{hook_name}", chunk, recent_output, %{
        workspace: workspace,
        hook: hook_name
      })
    end)
    |> handle_local_hook_result(%{
      workspace: workspace,
      issue_context: issue_context,
      hook_name: hook_name,
      worker_host: nil,
      command: command,
      started_at: started_at,
      opts: opts
    })
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_override_ms, opts) when is_binary(worker_host) do
    timeout_ms = timeout_override_ms || Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)
    phase = phase_for_hook(hook_name)

    log_workspace_command_start(hook_name, issue_context, workspace, worker_host)
    log_phase(phase, :started, issue_context, workspace, worker_host)
    persist_phase_event(phase, :started, issue_context, workspace, worker_host, started_at, %{})

    emit_system_progress(opts, issue_context, %{
      phase: phase,
      operation: "hook:#{hook_name}",
      status: "started",
      detail: "Running #{hook_name}",
      workspace: workspace,
      hook: hook_name,
      worker_host: worker_host_for_log(worker_host)
    })

    case Remote.run_command(worker_host, Remote.hook_script(workspace, command), timeout_ms) do
      {:ok, {output, status}} ->
        handle_hook_command_result(
          {output, status},
          workspace,
          issue_context,
          hook_name,
          worker_host,
          command,
          started_at,
          opts
        )

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        persist_phase_event(phase, :failed, issue_context, workspace, worker_host, started_at, %{
          reason: inspect(reason)
        })

        {:error, reason}

      {:error, reason} ->
        persist_phase_event(phase, :failed, issue_context, workspace, worker_host, started_at, %{
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp handle_local_hook_result({:ok, {output, status}}, context) do
    handle_hook_command_result(
      {output, status},
      context.workspace,
      context.issue_context,
      context.hook_name,
      context.worker_host,
      context.command,
      context.started_at,
      context.opts
    )
  end

  defp handle_local_hook_result({:error, {:workspace_hook_timeout, _command_name, timeout_ms, details}}, context) do
    Logger.warning(
      "Workspace hook timed out hook=#{context.hook_name} #{issue_log_context(context.issue_context)} workspace=#{context.workspace} worker_host=#{worker_host_for_log(context.worker_host)} timeout_ms=#{timeout_ms} elapsed_ms=#{Map.get(details, :elapsed_ms)} output=#{inspect(Map.get(details, :recent_output, ""))}"
    )

    persist_hook_event(
      "workspace.hook_timeout",
      context.issue_context,
      context.hook_name,
      context.workspace,
      context.worker_host,
      context.command,
      context.started_at,
      %{
        timeout_ms: timeout_ms,
        elapsed_ms: Map.get(details, :elapsed_ms),
        recent_output: Map.get(details, :recent_output, "")
      }
    )

    persist_phase_event(
      phase_for_hook(context.hook_name),
      :failed,
      context.issue_context,
      context.workspace,
      context.worker_host,
      context.started_at,
      %{
        reason: "timeout",
        timeout_ms: timeout_ms,
        elapsed_ms: Map.get(details, :elapsed_ms),
        recent_output: Map.get(details, :recent_output, "")
      }
    )

    emit_system_progress(context.opts, context.issue_context, %{
      phase: phase_for_hook(context.hook_name),
      operation: "hook:#{context.hook_name}",
      status: "failed",
      detail: "Timed out running #{context.hook_name}",
      workspace: context.workspace,
      hook: context.hook_name,
      output: Map.get(details, :recent_output, "")
    })

    {:error, {:workspace_hook_timeout, context.hook_name, timeout_ms, details}}
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    handle_hook_command_result(
      {output, status},
      workspace,
      issue_context,
      hook_name,
      nil,
      nil,
      System.monotonic_time(:millisecond)
    )
  end

  defp handle_hook_command_result(result, workspace, issue_context, hook_name, worker_host, command, started_at, opts \\ [])

  defp handle_hook_command_result({_output, 0}, workspace, issue_context, hook_name, worker_host, command, started_at, opts) do
    persist_hook_event(
      "workspace.hook_completed",
      issue_context,
      hook_name,
      workspace,
      worker_host,
      command,
      started_at,
      %{status: 0}
    )

    persist_phase_event(
      phase_for_hook(hook_name),
      :completed,
      issue_context,
      workspace,
      worker_host,
      started_at,
      %{exit_status: 0}
    )

    emit_system_progress(opts, issue_context, %{
      phase: phase_for_hook(hook_name),
      operation: "hook:#{hook_name}",
      status: "completed",
      detail: "Completed #{hook_name}",
      workspace: workspace,
      hook: hook_name
    })

    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, worker_host, command, started_at, opts) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    persist_hook_event("workspace.hook_failed", issue_context, hook_name, workspace, worker_host, command, started_at, %{
      status: status,
      output: sanitized_output
    })

    persist_phase_event(phase_for_hook(hook_name), :failed, issue_context, workspace, worker_host, started_at, %{
      exit_status: status,
      output: sanitized_output
    })

    emit_system_progress(opts, issue_context, %{
      phase: phase_for_hook(hook_name),
      operation: "hook:#{hook_name}",
      status: "failed",
      detail: "Failed running #{hook_name}",
      workspace: workspace,
      hook: hook_name,
      output: sanitized_output
    })

    {:error, {:workspace_hook_failed, hook_name, status, sanitized_output}}
  end

  defp run_local_hook_command(command, workspace, timeout_ms, on_output) do
    HookRunner.run_local(command, workspace, timeout_ms, on_output)
  end

  defp progress_callback(opts, issue_context, phase, operation, prefix) do
    fn chunk, recent_output ->
      emit_system_output(opts, issue_context, phase, operation, prefix, chunk, recent_output, %{})
    end
  end

  defp emit_system_output(opts, issue_context, phase, operation, prefix, chunk, recent_output, extra_metadata) do
    detail =
      chunk
      |> latest_progress_line()
      |> case do
        "" -> latest_progress_line(recent_output)
        line -> line
      end

    if detail != "" do
      emit_system_progress(
        opts,
        issue_context,
        Map.merge(
          %{
            phase: phase,
            operation: operation,
            status: "running",
            detail: "#{prefix}: #{detail}",
            output: recent_output
          },
          extra_metadata
        )
      )
    end
  end

  defp latest_progress_line(output) do
    output
    |> to_string()
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> List.last()
    |> to_string()
    |> String.trim()
  end

  defp emit_system_progress(opts, issue_context, metadata) when is_list(opts) and is_map(issue_context) and is_map(metadata) do
    case {Keyword.get(opts, :progress_recipient), Map.get(issue_context, :issue_id)} do
      {recipient, issue_id} when is_pid(recipient) and is_binary(issue_id) ->
        send(
          recipient,
          {:system_worker_update, issue_id,
           metadata
           |> Map.put_new(:source, :system)
           |> Map.put_new(:occurred_at, DateTime.utc_now())}
        )

      _ ->
        :ok
    end
  end

  defp emit_system_progress(_opts, _issue_context, _metadata), do: :ok

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    HookRunner.sanitize_output(output, max_bytes)
  end

  defp log_workspace_command_start("project_bootstrap", issue_context, workspace, nil) do
    Logger.info("Running project bootstrap #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")
  end

  defp log_workspace_command_start("project_bootstrap", issue_context, workspace, worker_host) do
    Logger.info("Running project bootstrap #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")
  end

  defp log_workspace_command_start(hook_name, issue_context, workspace, nil) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")
  end

  defp log_workspace_command_start(hook_name, issue_context, workspace, worker_host) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")
  end

  defp persist_hook_output(issue_context, hook_name, workspace, worker_host, command, started_at, chunk, recent_output) do
    sanitized_chunk = sanitize_hook_output_for_log(chunk, @hook_event_output_bytes)

    persist_hook_event("workspace.hook_output", issue_context, hook_name, workspace, worker_host, command, started_at, %{
      output: sanitized_chunk,
      recent_output: sanitize_hook_output_for_log(recent_output, @hook_recent_output_bytes)
    })
  end

  defp persist_hook_event(event_type, issue_context, hook_name, workspace, worker_host, command, started_at, payload) do
    payload =
      Map.merge(
        %{
          hook: hook_name,
          workspace: workspace,
          worker_host: worker_host_for_log(worker_host),
          command: command_preview(command),
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        },
        payload
      )

    PersistenceProvider.module().record_event(%{
      issue_identifier: Map.get(issue_context, :issue_identifier),
      event_type: event_type,
      payload: payload
    })

    :ok
  end

  defp phase_for_hook("project_bootstrap"), do: "workspace_bootstrap"
  defp phase_for_hook("after_create"), do: "workspace_after_create"
  defp phase_for_hook("before_run"), do: "before_run"
  defp phase_for_hook("after_run"), do: "after_run"
  defp phase_for_hook("before_remove"), do: "workspace_cleanup"
  defp phase_for_hook(hook_name), do: "workspace_hook:#{hook_name}"

  defp log_phase(phase, status, issue_context, workspace, worker_host) do
    Logger.info("Run phase phase=#{phase} status=#{status} #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} workspace=#{workspace}")
  end

  defp persist_phase_event(phase, status, issue_context, workspace, worker_host, started_at, payload) do
    payload =
      Map.merge(
        %{
          phase: phase,
          status: to_string(status),
          workspace: workspace,
          worker_host: worker_host_for_log(worker_host),
          elapsed_ms: System.monotonic_time(:millisecond) - started_at
        },
        payload
      )

    PersistenceProvider.module().record_event(%{
      issue_identifier: Map.get(issue_context, :issue_identifier),
      event_type: "run.phase",
      payload: payload
    })

    :ok
  rescue
    _ -> :ok
  end

  defp command_preview(nil), do: nil

  defp command_preview(command) when is_binary(command) do
    sanitize_hook_output_for_log(command, @hook_command_preview_bytes)
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root())
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
