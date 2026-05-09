defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, PersistenceProvider, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @hook_recent_output_bytes 4_096
  @hook_event_output_bytes 2_048
  @hook_command_preview_bytes 512

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
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
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\"",
        "mkdir -p \"$workspace\"",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' '1' \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

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

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    case created? do
      true ->
        run_after_create_commands(workspace, issue_context, worker_host)

      false ->
        :ok
    end
  end

  defp run_after_create_commands(workspace, issue_context, worker_host) do
    hooks = Config.settings!().hooks

    [
      {"project_bootstrap", Config.generated_after_create_hook()},
      {"after_create", hooks.after_create}
    ]
    |> Enum.reject(fn {_hook_name, command} -> blank?(command) end)
    |> Enum.reduce_while(:ok, fn {hook_name, command}, :ok ->
      case run_hook(command, workspace, issue_context, hook_name, worker_host) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
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

  defp blank?(value), do: String.trim(to_string(value || "")) == ""

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)
    phase = phase_for_hook(hook_name)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")
    log_phase(phase, :started, issue_context, workspace, nil)
    persist_phase_event(phase, :started, issue_context, workspace, nil, started_at, %{})
    persist_hook_event("workspace.hook_started", issue_context, hook_name, workspace, nil, command, started_at, %{})

    command
    |> run_local_hook_command(workspace, timeout_ms, fn chunk, recent_output ->
      persist_hook_output(issue_context, hook_name, workspace, nil, command, started_at, chunk, recent_output)
    end)
    |> handle_local_hook_result(workspace, issue_context, hook_name, nil, command, started_at, timeout_ms)
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)
    phase = phase_for_hook(hook_name)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")
    log_phase(phase, :started, issue_context, workspace, worker_host)
    persist_phase_event(phase, :started, issue_context, workspace, worker_host, started_at, %{})

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, {output, status}} ->
        handle_hook_command_result(
          {output, status},
          workspace,
          issue_context,
          hook_name,
          worker_host,
          command,
          started_at
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

  defp handle_local_hook_result({:ok, {output, status}}, workspace, issue_context, hook_name, worker_host, command, started_at, _timeout_ms) do
    handle_hook_command_result({output, status}, workspace, issue_context, hook_name, worker_host, command, started_at)
  end

  defp handle_local_hook_result({:error, {:workspace_hook_timeout, _command_name, timeout_ms, details}}, workspace, issue_context, hook_name, worker_host, command, started_at, _timeout_ms) do
    Logger.warning(
      "Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} timeout_ms=#{timeout_ms} elapsed_ms=#{Map.get(details, :elapsed_ms)} output=#{inspect(Map.get(details, :recent_output, ""))}"
    )

    persist_hook_event("workspace.hook_timeout", issue_context, hook_name, workspace, worker_host, command, started_at, %{
      timeout_ms: timeout_ms,
      elapsed_ms: Map.get(details, :elapsed_ms),
      recent_output: Map.get(details, :recent_output, "")
    })

    persist_phase_event(phase_for_hook(hook_name), :failed, issue_context, workspace, worker_host, started_at, %{
      reason: "timeout",
      timeout_ms: timeout_ms,
      elapsed_ms: Map.get(details, :elapsed_ms),
      recent_output: Map.get(details, :recent_output, "")
    })

    {:error, {:workspace_hook_timeout, hook_name, timeout_ms, details}}
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

  defp handle_hook_command_result({_output, 0}, workspace, issue_context, hook_name, worker_host, command, started_at) do
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

    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, worker_host, command, started_at) do
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

    {:error, {:workspace_hook_failed, hook_name, status, sanitized_output}}
  end

  defp run_local_hook_command(command, workspace, timeout_ms, on_output) do
    started_at = System.monotonic_time(:millisecond)
    port = open_hook_port(command, workspace)

    receive_hook_port(port, timeout_ms, started_at, "", on_output)
  end

  defp open_hook_port(command, workspace) do
    sh = System.find_executable("sh") || "/bin/sh"

    Port.open({:spawn_executable, sh}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-lc", command]},
      {:cd, workspace},
      {:env, [{~c"GIT_TERMINAL_PROMPT", ~c"0"}]}
    ])
  end

  defp receive_hook_port(port, timeout_ms, started_at, recent_output, on_output) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(timeout_ms - elapsed_ms, 0)

    receive do
      {^port, {:data, chunk}} ->
        sanitized_chunk = sanitize_hook_output_for_log(chunk, @hook_recent_output_bytes)
        recent_output = append_recent_output(recent_output, sanitized_chunk)
        on_output.(chunk, recent_output)
        receive_hook_port(port, timeout_ms, started_at, recent_output, on_output)

      {^port, {:exit_status, status}} ->
        {:ok, {recent_output, status}}
    after
      remaining_ms ->
        close_hook_port(port)

        details = %{
          elapsed_ms: System.monotonic_time(:millisecond) - started_at,
          recent_output: recent_output
        }

        {:error, {:workspace_hook_timeout, "local_command", timeout_ms, details}}
    end
  end

  defp close_hook_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp append_recent_output(current, chunk) do
    output = current <> IO.iodata_to_binary(chunk)

    case byte_size(output) <= @hook_recent_output_bytes do
      true -> output
      false -> binary_part(output, byte_size(output) - @hook_recent_output_bytes, @hook_recent_output_bytes)
    end
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)
    binary_output = scrub_sensitive_output(binary_output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp scrub_sensitive_output(output) do
    output
    |> String.replace(~r/(?i)(authorization\s*[:=]\s*)(bearer|basic)?\s*[^\s,;]+/, "\\1[REDACTED]")
    |> String.replace(~r/(?i)((?:api[_-]?key|token|secret)\s*[:=]\s*)[^\s,;]+/, "\\1[REDACTED]")
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
    expanded_root = Path.expand(Config.settings!().workspace.root)
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

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
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
