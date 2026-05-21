defmodule SymphonyElixir.Codex.Startup do
  @moduledoc """
  Startup command construction and failure classification for Codex app-server.
  """

  @startup_output_max_bytes 4_096
  @sensitive_codex_env_names ~w(
    LINEAR_API_KEY
    LINEAR_TOKEN
    GITHUB_TOKEN
    GH_TOKEN
    SLACK_BOT_TOKEN
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
  )

  @spec launch_command(map()) :: String.t()
  def launch_command(codex) when is_map(codex) do
    [
      pre_start_script(Map.get(codex, :pre_start_commands) || Map.get(codex, "pre_start_commands")),
      command_script(Map.get(codex, :command) || Map.get(codex, "command"))
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @spec pre_start_script([String.t()] | String.t() | nil) :: [String.t()]
  def pre_start_script(commands) do
    commands
    |> List.wrap()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {command, index} ->
      [
        "__symphony_codex_pre_start_index=#{index}",
        "#{command} || { __symphony_codex_pre_start_status=$?; printf '%s\\n' #{SymphonyElixir.Shell.escape("Symphony Codex pre-start command #{index} failed. See Settings / Workflow / Codex / Pre-start commands.")} >&2; exit $__symphony_codex_pre_start_status; }"
      ]
    end)
    |> List.flatten()
  end

  @spec command_script(String.t() | nil) :: String.t()
  def command_script(command) when is_binary(command) do
    if shell_control_command?(command), do: command, else: "exec #{command}"
  end

  def command_script(_command), do: ""

  @spec failure(term(), atom(), map(), String.t(), pos_integer()) :: {:codex_startup_failed, map()}
  def failure(reason, stage, context, output, timeout_ms) do
    base = %{
      reason: startup_reason(reason),
      stage: stage,
      command: Map.get(context, :command),
      workspace: Map.get(context, :workspace),
      worker_host: Map.get(context, :worker_host) || "local",
      output: sanitize_output(output),
      hint: hint(reason),
      timeout_ms: timeout_ms
    }

    details =
      case reason do
        {:port_exit, status} -> Map.put(base, :exit_status, status)
        {:response_error, error} -> Map.put(base, :response_error, error)
        _ -> base
      end

    {:codex_startup_failed, details}
  end

  @spec append_output(String.t(), term()) :: String.t()
  def append_output(output, chunk) do
    text = chunk |> to_string() |> String.trim()

    cond do
      text == "" -> output
      output == "" -> truncate_output(text)
      true -> truncate_output(output <> "\n" <> text)
    end
  end

  @spec sanitize_output(term()) :: String.t()
  def sanitize_output(output) when is_binary(output) do
    output
    |> SymphonyElixir.Redaction.sensitive_env_values(@sensitive_codex_env_names)
    |> SymphonyElixir.Redaction.credentials()
  end

  def sanitize_output(_output), do: ""

  @spec hint(term()) :: String.t()
  def hint({:port_exit, 127}), do: "Command not found or shell initialization failed before codex app-server became ready."

  def hint({:port_exit, _status}), do: "Codex startup failed before the session handshake completed. Check Settings / Workflow / Codex / Pre-start commands and Command."

  def hint({:response_error, error}) do
    error
    |> response_error_message()
    |> approval_policy_error?()
    |> case do
      true -> "Codex rejected approvalPolicy. Open Settings / Workflow / Codex / Approval policy and choose one of: untrusted, on-failure, on-request, granular, never."
      false -> "Codex app-server startup failed before the session handshake completed."
    end
  end

  def hint(:response_timeout), do: "Codex app-server did not respond before codex.read_timeout_ms; increase read_timeout_ms or reduce shell startup work."
  def hint(_reason), do: "Codex app-server startup failed before the session handshake completed."

  defp startup_reason({:port_exit, _status}), do: :port_exit
  defp startup_reason({:response_error, _error}), do: :response_error
  defp startup_reason(reason), do: reason

  defp shell_control_command?(command), do: String.contains?(command, ["\n", ";", "&&", "||"])

  defp response_error_message(%{"message" => message}) when is_binary(message), do: message
  defp response_error_message(%{message: message}) when is_binary(message), do: message
  defp response_error_message(error), do: inspect(error)

  defp approval_policy_error?(message) do
    String.contains?(message, "approvalPolicy") or
      (String.contains?(message, "unknown variant") and String.contains?(message, "reject"))
  end

  defp truncate_output(output) do
    if String.length(output) > @startup_output_max_bytes do
      String.slice(output, 0, @startup_output_max_bytes) <> "... (truncated)"
    else
      output
    end
  end

  defp blank?(value), do: SymphonyElixir.Text.blankish?(value)
end
