# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Workspace.Sections.Lifecycle do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      require Logger
      alias SymphonyElixir.{Config, PathSafety, PersistenceEventWriter, WorkspaceCleanupPolicy}
      alias SymphonyElixir.Workspace.{HookRunner, Remote, SourcePreparation}

      @hook_recent_output_bytes 4096
      @hook_event_output_bytes 2048
      @hook_command_preview_bytes 512

      @type worker_host :: String.t() | nil

      @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
              {:ok, Path.t()} | {:error, term()}
      def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
        issue_context = issue_context(issue_or_identifier)

        try do
          safe_id = SourcePreparation.safe_identifier(issue_context.issue_identifier)

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
               :ok <-
                 maybe_run_after_create_commands(workspace, issue_context, created?, worker_host, opts) do
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
        with :ok <-
               WorkspaceCleanupPolicy.validate_remote_delete(
                 workspace,
                 Config.settings!().workspace.root
               ) do
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
      def remove(workspace) do
        remove(workspace, nil)
      end

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
      def remove_issue_workspaces(identifier) do
        remove_issue_workspaces(identifier, nil)
      end

      @spec remove_issue_workspaces(term(), worker_host()) :: :ok
      def remove_issue_workspaces(identifier, worker_host)
          when is_binary(identifier) and is_binary(worker_host) do
        safe_id = SourcePreparation.safe_identifier(identifier)

        case workspace_path_for_issue(safe_id, worker_host) do
          {:ok, workspace} -> remove(workspace, worker_host)
          {:error, _reason} -> :ok
        end

        :ok
      end

      def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
        safe_id = SourcePreparation.safe_identifier(identifier)

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
      def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
          when is_binary(workspace) do
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
      def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
          when is_binary(workspace) do
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
        SourcePreparation.workspace_path_for_issue(safe_id, nil, Config.settings!())
      end

      defp workspace_path_for_issue(safe_id, worker_host)
           when is_binary(safe_id) and is_binary(worker_host) do
        SourcePreparation.workspace_path_for_issue(safe_id, worker_host, Config.settings!())
      end

      defp workspace_root do
        Config.settings!()
        |> SourcePreparation.workspace_root()
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
          run_optional_hook(
            hooks.after_create,
            workspace,
            issue_context,
            "after_create",
            worker_host,
            nil,
            opts
          )
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

      defp run_project_bootstrap(workspace, issue_context, worker_host, opts)
           when is_binary(worker_host) do
        settings = Config.settings!()

        case settings.project.source_strategy do
          "worktree" ->
            {:error, {:unsupported_remote_source_strategy, "worktree", worker_host}}

          _clone ->
            run_optional_hook(
              worker_project_bootstrap_commands(),
              workspace,
              issue_context,
              "project_bootstrap",
              worker_host,
              settings.workspace.initialize_timeout_ms,
              opts
            )
        end
      end

      @spec worker_project_bootstrap_commands() :: String.t()
      defp worker_project_bootstrap_commands do
        case Config.generated_project_bootstrap_commands() do
          nil ->
            "if [ -f mix.exs ]; then mix local.hex --force && mix deps.get; fi"

          commands ->
            "if [ -f mix.exs ]; then mix local.hex --force && mix deps.get; fi\n" <> commands
        end
      end

      defp run_optional_hook(
             command,
             workspace,
             issue_context,
             hook_name,
             worker_host,
             timeout_ms,
             opts
           ) do
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

        persist_phase_event(
          "workspace_bootstrap",
          :started,
          issue_context,
          workspace,
          nil,
          started_at,
          %{source_strategy: "worktree"}
        )

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
               :ok <-
                 cleanup_stale_worktree(base_path, workspace, project, timeout_ms, opts, issue_context) do
            add_worktree(
              base_path,
              workspace,
              branch,
              project.default_branch,
              timeout_ms,
              opts,
              issue_context
            )
          end

        case result do
          :ok ->
            persist_phase_event(
              "workspace_bootstrap",
              :completed,
              issue_context,
              workspace,
              nil,
              started_at,
              %{
                source_strategy: "worktree",
                base_path: base_path,
                branch: branch
              }
            )

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
            persist_phase_event(
              "workspace_bootstrap",
              :failed,
              issue_context,
              workspace,
              nil,
              started_at,
              %{
                source_strategy: "worktree",
                base_path: base_path,
                reason: inspect(reason)
              }
            )

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
            with :ok <-
                   validate_cleanup_delete(base_path, [
                     SourcePreparation.repository_base_root(Config.settings!())
                   ]) do
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

        run_git(
          parent,
          args,
          timeout_ms,
          progress_callback(
            opts,
            issue_context,
            "workspace_bootstrap",
            "git_clone",
            "Cloning base repository"
          )
        )
      end

      defp maybe_fetch_worktree_base(
             %{worktree_fetch: false},
             _base_path,
             _timeout_ms,
             _opts,
             _issue_context
           ) do
        :ok
      end

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
                 progress_callback(
                   opts,
                   issue_context,
                   "workspace_bootstrap",
                   "git_fetch",
                   "Fetching base repository"
                 )
               ),
             :ok <- update_worktree_base_branch(base_path, branch, timeout_ms, opts, issue_context) do
          :ok
        else
          {:error, reason} ->
            {:error, {:worktree_source_sync_failed, project.repository_url, branch, reason}}
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

        with :ok <-
               run_git(
                 base_path,
                 ["rev-parse", "--verify", "refs/remotes/origin/#{branch}"],
                 timeout_ms
               ),
             :ok <-
               run_git(
                 base_path,
                 ["update-ref", "refs/heads/#{branch}", "refs/remotes/origin/#{branch}"],
                 timeout_ms
               ) do
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

      defp cleanup_stale_worktree(
             base_path,
             workspace,
             %{worktree_cleanup: false},
             timeout_ms,
             opts,
             issue_context
           ) do
        if File.exists?(workspace) do
          {:error, {:worktree_exists, workspace}}
        else
          run_git(
            base_path,
            ["worktree", "prune"],
            timeout_ms,
            progress_callback(
              opts,
              issue_context,
              "workspace_bootstrap",
              "worktree_prune",
              "Pruning stale worktrees"
            )
          )
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
              progress_callback(
                opts,
                issue_context,
                "workspace_bootstrap",
                "worktree_prune",
                "Pruning stale worktrees"
              )
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
          progress_callback(
            opts,
            issue_context,
            "workspace_bootstrap",
            "worktree_add",
            "Creating project worktree"
          )
        )
      end

      defp worktree_base_ref(base_path, branch, timeout_ms) when is_binary(branch) and branch != "" do
        case run_git(base_path, ["rev-parse", "--verify", branch], timeout_ms) do
          :ok -> branch
          {:error, _reason} -> "origin/#{branch}"
        end
      end

      defp worktree_base_ref(_base_path, _branch, _timeout_ms) do
        "HEAD"
      end

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

      defp repository_cache_path(settings) do
        SourcePreparation.repository_cache_path(settings)
      end

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

        WorkspaceCleanupPolicy.validate_local_delete(path,
          roots: roots,
          protected_paths: protected_paths
        )
      end

      defp run_git(cwd, args) do
        executable = System.find_executable("git") || "git"

        case System.cmd(executable, args,
               cd: cwd,
               stderr_to_stdout: true,
               env: [{"GIT_TERMINAL_PROMPT", "0"}]
             ) do
          {_output, 0} ->
            :ok

          {output, status} ->
            {:error, {:git_command_failed, args, status, sanitize_hook_output_for_log(output)}}
        end
      rescue
        error -> {:error, error}
      end

      defp run_git(cwd, args, nil) do
        run_git(cwd, args)
      end

      defp run_git(cwd, args, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
        run_git(cwd, args, timeout_ms, fn _chunk, _recent_output -> :ok end)
      end
    end
  end
end
