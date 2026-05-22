defmodule SymphonyElixir.Codex.MessageHumanizer.WrapperEvents do
  @moduledoc """
  Formatter for `codex/event/*` wrapper events emitted by Codex app-server.
  """

  alias SymphonyElixir.Codex.MessageUsageFormatter

  @doc false
  @spec humanize(String.t(), map()) :: String.t()
  def humanize(event, payload), do: humanize_codex_wrapper_event(event, payload)

  defp humanize_codex_wrapper_event("mcp_startup_update", payload) do
    server =
      SymphonyElixir.Payload.get_path(payload, ["params", "msg", "server"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :server]) ||
        "mcp"

    state =
      SymphonyElixir.Payload.get_path(payload, ["params", "msg", "status", "state"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :status, :state]) ||
        "updated"

    "mcp startup: #{server} #{state}"
  end

  defp humanize_codex_wrapper_event("mcp_startup_complete", _payload), do: "mcp startup complete"
  defp humanize_codex_wrapper_event("task_started", _payload), do: "task started"
  defp humanize_codex_wrapper_event("user_message", _payload), do: "user message received"

  defp humanize_codex_wrapper_event("item_started", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item started (#{humanize_item_type(type)})"
      _ -> "item started"
    end
  end

  defp humanize_codex_wrapper_event("item_completed", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item completed (#{humanize_item_type(type)})"
      _ -> "item completed"
    end
  end

  defp humanize_codex_wrapper_event("agent_message_delta", payload),
    do: humanize_streaming_event("agent message streaming", payload)

  defp humanize_codex_wrapper_event("agent_message_content_delta", payload),
    do: humanize_streaming_event("agent message content streaming", payload)

  defp humanize_codex_wrapper_event("agent_reasoning_delta", payload),
    do: humanize_streaming_event("reasoning streaming", payload)

  defp humanize_codex_wrapper_event("reasoning_content_delta", payload),
    do: humanize_streaming_event("reasoning content streaming", payload)

  defp humanize_codex_wrapper_event("agent_reasoning_section_break", _payload), do: "reasoning section break"
  defp humanize_codex_wrapper_event("agent_reasoning", payload), do: humanize_reasoning_update(payload)
  defp humanize_codex_wrapper_event("turn_diff", _payload), do: "turn diff updated"
  defp humanize_codex_wrapper_event("exec_command_begin", payload), do: humanize_exec_command_begin(payload)
  defp humanize_codex_wrapper_event("exec_command_end", payload), do: humanize_exec_command_end(payload)
  defp humanize_codex_wrapper_event("exec_command_output_delta", _payload), do: "command output streaming"
  defp humanize_codex_wrapper_event("mcp_tool_call_begin", _payload), do: "mcp tool call started"
  defp humanize_codex_wrapper_event("mcp_tool_call_end", _payload), do: "mcp tool call completed"

  defp humanize_codex_wrapper_event("token_count", payload) do
    usage = extract_first_path(payload, token_usage_paths())

    case MessageUsageFormatter.format_usage_counts(usage) do
      nil -> "token count update"
      usage_text -> "token count update (#{usage_text})"
    end
  end

  defp humanize_codex_wrapper_event(other, payload) do
    msg_type =
      SymphonyElixir.Payload.get_path(payload, ["params", "msg", "type"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :type])

    if is_binary(msg_type), do: "#{other} (#{msg_type})", else: other
  end

  defp humanize_exec_command_begin(payload) do
    command =
      SymphonyElixir.Payload.get_path(payload, ["params", "msg", "command"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :command]) ||
        SymphonyElixir.Payload.get_path(payload, ["params", "msg", "parsed_cmd"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :parsed_cmd])

    command = normalize_command(command)
    if is_binary(command), do: command, else: "command started"
  end

  defp humanize_exec_command_end(payload) do
    exit_code =
      SymphonyElixir.Payload.get_path(payload, ["params", "msg", "exit_code"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :exit_code]) ||
        SymphonyElixir.Payload.get_path(payload, ["params", "msg", "exitCode"]) ||
        SymphonyElixir.Payload.get_path(payload, [:params, :msg, :exitCode])

    if is_integer(exit_code), do: "command completed (exit #{exit_code})", else: "command completed"
  end

  defp humanize_streaming_event(label, payload) do
    case extract_delta_preview(payload) do
      nil -> label
      preview -> "#{label}: #{preview}"
    end
  end

  defp humanize_reasoning_update(payload) do
    case extract_reasoning_focus(payload) do
      nil -> "reasoning update"
      focus -> "reasoning update: #{focus}"
    end
  end

  defp extract_reasoning_focus(payload) do
    value = extract_first_path(payload, reasoning_focus_paths())

    if is_binary(value) do
      trimmed = String.trim(value)
      if trimmed == "", do: nil, else: inline_text(trimmed)
    end
  end

  defp extract_delta_preview(payload) do
    case extract_first_path(payload, delta_paths()) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: inline_text(trimmed)

      _ ->
        nil
    end
  end

  defp wrapper_payload_type(payload) do
    SymphonyElixir.Payload.get_path(payload, ["params", "msg", "payload", "type"]) ||
      SymphonyElixir.Payload.get_path(payload, [:params, :msg, :payload, :type])
  end

  defp normalize_command(%{} = command) do
    binary_command = SymphonyElixir.Payload.get_any(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = SymphonyElixir.Payload.get_any(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args), do: normalize_command([binary_command | args]), else: normalize_command(binary_command || args)
  end

  defp normalize_command(command) when is_binary(command), do: inline_text(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1), do: command |> Enum.join(" ") |> inline_text()
  end

  defp normalize_command(_command), do: nil

  defp humanize_item_type(nil), do: "item"

  defp humanize_item_type(type) when is_binary(type) do
    type
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.replace("/", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_item_type(type), do: to_string(type)

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp token_usage_paths do
    [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total]
    ]
  end

  defp delta_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "msg", "outputDelta"],
      [:params, :msg, :outputDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "outputDelta"],
      [:params, :msg, :payload, :outputDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end

  defp reasoning_focus_paths do
    [
      ["params", "reason"],
      [:params, :reason],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "summary"],
      [:params, :summary],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "reason"],
      [:params, :msg, :reason],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "summary"],
      [:params, :msg, :summary],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "payload", "reason"],
      [:params, :msg, :payload, :reason],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "summary"],
      [:params, :msg, :payload, :summary],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text]
    ]
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, fn path -> SymphonyElixir.Payload.get_path(payload, path) end)
  end

  defp truncate(value, max) when byte_size(value) > max, do: value |> String.slice(0, max) |> Kernel.<>("...")
  defp truncate(value, _max), do: value
end
