defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger

  alias SymphonyElixir.{
    Codex.DynamicTool,
    Codex.Protocol,
    Codex.Startup,
    Codex.ToolRequestHandler,
    Config,
    PathSafety,
    RuntimeProxy,
    SSH
  }

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @sensitive_codex_env_names ~w(
    LINEAR_API_KEY
    LINEAR_TOKEN
    GITHUB_TOKEN
    GH_TOKEN
    SLACK_BOT_TOKEN
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
  )

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      startup_context = startup_context(expanded_workspace, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies, startup_context) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments,
          issue: issue,
          profile: Config.workflow_profile_for_state(issue.state),
          workspace: Keyword.get(opts, :workspace, workspace)
        )
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    roots = workspace_allowed_roots()

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_roots} <- canonical_workspace_roots(roots) do
      validate_workspace_against_roots(canonical_workspace, expanded_workspace, canonical_roots)
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp workspace_allowed_roots do
    workspace = Config.settings!().workspace

    [
      workspace.root,
      workspace.worktree_base_root
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp canonical_workspace_roots(roots) do
    roots
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, canonical_roots} ->
      case PathSafety.canonicalize(root) do
        {:ok, canonical_root} -> {:cont, {:ok, [{root, canonical_root} | canonical_roots]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, canonical_roots} -> {:ok, Enum.reverse(canonical_roots)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workspace_against_roots(canonical_workspace, expanded_workspace, roots) do
    exact_root = Enum.find(roots, fn {_expanded_root, canonical_root} -> canonical_workspace == canonical_root end)
    matching_root = Enum.find(roots, fn {_expanded_root, canonical_root} -> under_root?(canonical_workspace, canonical_root) end)
    symlink_root = Enum.find(roots, fn {expanded_root, _canonical_root} -> under_root?(expanded_workspace, expanded_root) end)

    cond do
      exact_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

      matching_root ->
        {:ok, canonical_workspace}

      symlink_root ->
        {_expanded_root, canonical_root} = symlink_root
        {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

      true ->
        {_expanded_root, canonical_root} = List.first(roots)
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
    end
  end

  defp under_root?(path, root), do: String.starts_with?(path <> "/", root <> "/")

  defp blank?(value), do: SymphonyElixir.Text.blank?(value)

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command())],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
          |> maybe_put_proxy_env()
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      RuntimeProxy.remote_exports(),
      unset_sensitive_env_command(),
      "cd #{SymphonyElixir.Shell.escape(workspace)}",
      codex_launch_command()
    ]
    |> List.flatten()
    |> Enum.join(" && ")
  end

  defp local_launch_command do
    codex_launch_command()
  end

  defp codex_launch_command do
    Config.settings!().codex
    |> Map.from_struct()
    |> Startup.launch_command()
  end

  defp maybe_put_proxy_env(port_opts) do
    case codex_port_env() do
      [] -> port_opts
      env -> Keyword.put(port_opts, :env, env)
    end
  end

  defp codex_port_env do
    RuntimeProxy.port_env() ++
      Enum.map(@sensitive_codex_env_names, fn name ->
        {String.to_charlist(name), false}
      end)
  end

  defp unset_sensitive_env_command do
    "unset " <> Enum.join(@sensitive_codex_env_names, " ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp startup_context(workspace, worker_host) do
    %{
      command: Config.settings!().codex.command,
      workspace: workspace,
      worker_host: worker_host
    }
  end

  defp send_initialize(port, startup_context) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_startup_response(port, @initialize_id, :initialize, startup_context) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, startup_context) do
    case send_initialize(port, startup_context) do
      :ok -> start_thread(port, workspace, session_policies, startup_context)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}, startup_context) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_startup_response(port, @thread_start_id, :thread_start, startup_context) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp await_startup_response(port, request_id, stage, context) do
    with_timeout_startup_response(port, request_id, Config.settings!().codex.read_timeout_ms, "", "", stage, context)
  end

  defp with_timeout_startup_response(port, request_id, timeout_ms, pending_line, output, stage, context) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = Protocol.complete_line(pending_line, chunk)
        handle_startup_response(port, request_id, complete_line, timeout_ms, output, stage, context)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_startup_response(
          port,
          request_id,
          timeout_ms,
          Protocol.complete_line(pending_line, chunk),
          output,
          stage,
          context
        )

      {^port, {:exit_status, status}} ->
        {:error, Startup.failure({:port_exit, status}, stage, context, output, timeout_ms)}
    after
      timeout_ms ->
        output = append_startup_output(output, pending_line)
        {:error, Startup.failure(:response_timeout, stage, context, output, timeout_ms)}
    end
  end

  defp handle_startup_response(port, request_id, data, timeout_ms, output, stage, context) do
    case Protocol.decode_response_line(data, request_id) do
      {:response_result, result} ->
        {:ok, result}

      {:response_error, error} ->
        {:error, Startup.failure({:response_error, error}, stage, context, output, timeout_ms)}

      {:response_payload, payload} ->
        {:error, Startup.failure({:response_error, payload}, stage, context, output, timeout_ms)}

      {:other, _payload} ->
        with_timeout_startup_response(port, request_id, timeout_ms, "", output, stage, context)

      {:malformed, payload_string} ->
        log_non_json_stream_line(payload_string, "startup response stream")

        with_timeout_startup_response(
          port,
          request_id,
          timeout_ms,
          "",
          append_startup_output(output, payload_string),
          stage,
          context
        )
    end
  end

  defp append_startup_output(output, chunk) do
    Startup.append_output(output, chunk)
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = Protocol.complete_line(pending_line, chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          Protocol.complete_line(pending_line, chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    case Protocol.decode_turn_stream_line(data) do
      {:turn_completed, payload, payload_string} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:turn_failed, payload, params, payload_string} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          params
        )

        {:error, {:turn_failed, params}}

      {:turn_cancelled, payload, params, payload_string} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          params
        )

        {:error, {:turn_cancelled, params}}

      {:notification, method, payload, payload_string} ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:other, payload, payload_string} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:malformed_candidate, payload_string} ->
        log_non_json_stream_line(payload_string, "turn stream")

        emit_message(
          on_message,
          :malformed,
          %{
            payload: payload_string,
            raw: payload_string
          },
          metadata_from_message(port, %{raw: payload_string})
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:stream_line, payload_string} ->
        log_non_json_stream_line(payload_string, "turn stream")

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case ToolRequestHandler.handle(method, payload,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      {:reply, reply, event, extra_details} ->
        send_message(port, reply)

        emit_message(
          on_message,
          event,
          Map.merge(%{payload: payload, raw: payload_string}, extra_details),
          metadata
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if ToolRequestHandler.needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = Protocol.complete_line(pending_line, chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, Protocol.complete_line(pending_line, chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    case Protocol.decode_response_line(data, request_id) do
      {:response_error, error} ->
        {:error, {:response_error, error}}

      {:response_result, result} ->
        {:ok, result}

      {:response_payload, response_payload} ->
        {:error, {:response_error, response_payload}}

      {:other, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:other, _other} ->
        with_timeout_response(port, request_id, timeout_ms, "")

      {:malformed, payload} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    case Protocol.stream_log_entry(data) do
      {:warning, text} -> Logger.warning("Codex #{stream_label} output: #{text}")
      {:debug, text} -> Logger.debug("Codex #{stream_label} output: #{text}")
      nil -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = SymphonyElixir.Payload.get_any(payload, ["usage", :usage])

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp default_on_message(_message), do: :ok

  defp send_message(port, message) do
    Port.command(port, Protocol.encode_message(message))
  end
end
