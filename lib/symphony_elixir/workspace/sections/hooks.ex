# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Workspace.Sections.Hooks do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      require Logger
      alias SymphonyElixir.{Config, PathSafety, PersistenceEventWriter, WorkspaceCleanupPolicy}
      alias SymphonyElixir.Workspace.{HookRunner, Remote, SourcePreparation}

      defp run_git(cwd, args, timeout_ms, on_output) when is_integer(timeout_ms) and timeout_ms > 0 do
        executable = System.find_executable("git") || "git"

        command =
          SymphonyElixir.Shell.escape(executable) <>
            " " <> Enum.map_join(args, " ", &SymphonyElixir.Shell.escape/1)

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

      defp maybe_append_git_arg(args, _flag, nil) do
        args
      end

      defp maybe_append_git_arg(args, _flag, "") do
        args
      end

      defp maybe_append_git_arg(args, flag, value) do
        args ++ [flag, value]
      end

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
            Remote.run_command(
              worker_host,
              Remote.before_remove_script(workspace, command),
              Config.settings!().hooks.timeout_ms
            )
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

      defp ignore_hook_failure(:ok) do
        :ok
      end

      defp ignore_hook_failure({:error, _reason}) do
        :ok
      end

      defp blank?(value) do
        SymphonyElixir.Text.blankish?(value)
      end

      defp run_hook(
             command,
             workspace,
             issue_context,
             hook_name,
             worker_host,
             timeout_override_ms \\ nil,
             opts \\ []
           )

      defp run_hook(command, workspace, issue_context, hook_name, nil, timeout_override_ms, opts) do
        timeout_ms = timeout_override_ms || Config.settings!().hooks.timeout_ms
        started_at = System.monotonic_time(:millisecond)
        phase = phase_for_hook(hook_name)

        log_workspace_command_start(hook_name, issue_context, workspace, nil)
        log_phase(phase, :started, issue_context, workspace, nil)
        persist_phase_event(phase, :started, issue_context, workspace, nil, started_at, %{})

        persist_hook_event(
          "workspace.hook_started",
          issue_context,
          hook_name,
          workspace,
          nil,
          command,
          started_at,
          %{}
        )

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
          persist_hook_output(
            issue_context,
            hook_name,
            workspace,
            nil,
            command,
            started_at,
            chunk,
            recent_output
          )

          emit_system_output(
            opts,
            issue_context,
            phase,
            "hook:#{hook_name}",
            "Running #{hook_name}",
            chunk,
            recent_output,
            %{
              workspace: workspace,
              hook: hook_name
            }
          )
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

      defp run_hook(
             command,
             workspace,
             issue_context,
             hook_name,
             worker_host,
             timeout_override_ms,
             opts
           )
           when is_binary(worker_host) do
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

      defp handle_local_hook_result(
             {:error, {:workspace_hook_timeout, _command_name, timeout_ms, details}},
             context
           ) do
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

      defp handle_hook_command_result(
             result,
             workspace,
             issue_context,
             hook_name,
             worker_host,
             command,
             started_at,
             opts \\ []
           )

      defp handle_hook_command_result(
             {_output, 0},
             workspace,
             issue_context,
             hook_name,
             worker_host,
             command,
             started_at,
             opts
           ) do
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

      defp handle_hook_command_result(
             {output, status},
             workspace,
             issue_context,
             hook_name,
             worker_host,
             command,
             started_at,
             opts
           ) do
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

        persist_hook_event(
          "workspace.hook_failed",
          issue_context,
          hook_name,
          workspace,
          worker_host,
          command,
          started_at,
          %{
            status: status,
            output: sanitized_output
          }
        )

        persist_phase_event(
          phase_for_hook(hook_name),
          :failed,
          issue_context,
          workspace,
          worker_host,
          started_at,
          %{
            exit_status: status,
            output: sanitized_output
          }
        )

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

      defp emit_system_output(
             opts,
             issue_context,
             phase,
             operation,
             prefix,
             chunk,
             recent_output,
             extra_metadata
           ) do
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

      defp emit_system_progress(opts, issue_context, metadata)
           when is_list(opts) and is_map(issue_context) and is_map(metadata) do
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

      defp emit_system_progress(_opts, _issue_context, _metadata) do
        :ok
      end

      defp sanitize_hook_output_for_log(output, max_bytes \\ 2048) do
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

      defp persist_hook_output(
             issue_context,
             hook_name,
             workspace,
             worker_host,
             command,
             started_at,
             chunk,
             recent_output
           ) do
        sanitized_chunk = sanitize_hook_output_for_log(chunk, @hook_event_output_bytes)

        persist_hook_event(
          "workspace.hook_output",
          issue_context,
          hook_name,
          workspace,
          worker_host,
          command,
          started_at,
          %{
            output: sanitized_chunk,
            recent_output: sanitize_hook_output_for_log(recent_output, @hook_recent_output_bytes)
          }
        )
      end

      defp persist_hook_event(
             event_type,
             issue_context,
             hook_name,
             workspace,
             worker_host,
             command,
             started_at,
             payload
           ) do
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

        record_telemetry_event(
          %{
            issue_identifier: Map.get(issue_context, :issue_identifier),
            event_type: event_type,
            payload: payload
          },
          issue_context
        )
      end

      defp phase_for_hook("project_bootstrap") do
        "workspace_bootstrap"
      end

      defp phase_for_hook("after_create") do
        "workspace_after_create"
      end

      defp phase_for_hook("before_run") do
        "before_run"
      end

      defp phase_for_hook("after_run") do
        "after_run"
      end

      defp phase_for_hook("before_remove") do
        "workspace_cleanup"
      end

      defp phase_for_hook(hook_name) do
        "workspace_hook:#{hook_name}"
      end

      defp log_phase(phase, status, issue_context, workspace, worker_host) do
        Logger.info("Run phase phase=#{phase} status=#{status} #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} workspace=#{workspace}")
      end

      defp persist_phase_event(
             phase,
             status,
             issue_context,
             workspace,
             worker_host,
             started_at,
             payload
           ) do
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

        record_telemetry_event(
          %{
            issue_identifier: Map.get(issue_context, :issue_identifier),
            event_type: "run.phase",
            payload: payload
          },
          issue_context
        )
      end

      defp record_telemetry_event(attrs, issue_context) do
        case PersistenceEventWriter.record(attrs, issue_context) do
          :ok ->
            :ok

          {_outcome, reason} ->
            Logger.warning(
              "Workspace event persistence degraded action=continue_degraded event_type=#{Map.get(attrs, :event_type)} #{issue_log_context(issue_context)} session_id=n/a run_id=n/a outcome=#{inspect({:degraded, reason}, limit: 20, printable_limit: 1000)}"
            )

            :ok
        end
      end

      defp command_preview(nil) do
        nil
      end

      defp command_preview(command) when is_binary(command) do
        sanitize_hook_output_for_log(command, @hook_command_preview_bytes)
      end

      defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
        expanded_workspace = Path.expand(workspace)
        expanded_root = Path.expand(workspace_root())

        with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
             {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
          case PathSafety.classify_strict_descendant(
                 canonical_workspace,
                 expanded_workspace,
                 [{expanded_root, canonical_root}]
               ) do
            {:exact_root, _canonical_root} ->
              {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

            {:inside, _canonical_root} ->
              :ok

            {:symlink_escape, symlink_root} ->
              {:error, {:workspace_symlink_escape, expanded_workspace, symlink_root}}

            :outside ->
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

      defp worker_host_for_log(nil) do
        "local"
      end

      defp worker_host_for_log(worker_host) do
        worker_host
      end

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
  end
end
