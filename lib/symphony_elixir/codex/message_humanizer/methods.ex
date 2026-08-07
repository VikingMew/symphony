defmodule SymphonyElixir.Codex.MessageHumanizer.Methods do
  @moduledoc """
  Pure formatter for compact, operator-facing Codex protocol and event messages.
  """

  alias SymphonyElixir.Codex.MessageHumanizer.ToolMethods
  alias SymphonyElixir.Codex.MessageHumanizer.WrapperEvents
  alias SymphonyElixir.Codex.{MessageUsageFormatter, Protocol}
  alias SymphonyElixir.Codex.Protocol.Event

  @doc false
  @spec humanize(Event.t()) :: String.t()
  def humanize(%Event{} = event), do: humanize_codex_event(event)

  @doc false
  @spec humanize(String.t(), map()) :: String.t()
  def humanize(method, payload), do: payload |> Protocol.normalize_event(method) |> humanize_codex_event()

  @doc false
  @spec humanize_mcp(map()) :: String.t()
  def humanize_mcp(payload), do: ToolMethods.mcp_elicitation(payload)

  @doc false
  @spec humanize_dynamic_tool(String.t(), map()) :: String.t()
  def humanize_dynamic_tool(base, payload), do: ToolMethods.dynamic_tool_event(base, payload)

  defp humanize_codex_event(%Event{method: "thread/started", thread_id: thread_id}) do
    if is_binary(thread_id) do
      "thread started (#{thread_id})"
    else
      "thread started"
    end
  end

  defp humanize_codex_event(%Event{method: "turn/started", turn_id: turn_id}) do
    if is_binary(turn_id) do
      "turn started (#{turn_id})"
    else
      "turn started"
    end
  end

  defp humanize_codex_event(%Event{method: "turn/completed", turn_status: status, usage: usage}) do
    usage_suffix =
      case MessageUsageFormatter.format_usage_counts(usage) do
        nil -> ""
        usage_text -> " (#{usage_text})"
      end

    "turn completed (#{status || "completed"})#{usage_suffix}"
  end

  defp humanize_codex_event(%Event{method: "turn/failed", error_message: error_message}) do
    if is_binary(error_message), do: "turn failed: #{error_message}", else: "turn failed"
  end

  defp humanize_codex_event(%Event{method: "turn/cancelled"}), do: "turn cancelled"

  defp humanize_codex_event(%Event{method: "turn/diff/updated", params: params}) do
    diff = SymphonyElixir.Payload.get_any(params, ["diff", :diff])

    if is_binary(diff) and diff != "" do
      line_count =
        diff
        |> String.split("
",
          trim: true
        )
        |> length()

      "turn diff updated (#{line_count} lines)"
    else
      "turn diff updated"
    end
  end

  defp humanize_codex_event(%Event{method: "turn/plan/updated", plan_entries: plan_entries}) do
    if is_list(plan_entries) do
      "plan updated (#{length(plan_entries)} steps)"
    else
      "plan updated"
    end
  end

  defp humanize_codex_event(%Event{method: "thread/tokenUsage/updated", usage: usage}) do
    case MessageUsageFormatter.format_usage_counts(usage) do
      nil -> "thread token usage updated"
      usage_text -> "thread token usage updated (#{usage_text})"
    end
  end

  defp humanize_codex_event(%Event{method: "item/started"} = event), do: humanize_item_lifecycle("started", event)
  defp humanize_codex_event(%Event{method: "item/completed"} = event), do: humanize_item_lifecycle("completed", event)

  defp humanize_codex_event(%Event{method: "item/agentMessage/delta"} = event),
    do: humanize_streaming_event("agent message streaming", event)

  defp humanize_codex_event(%Event{method: "item/plan/delta"} = event),
    do: humanize_streaming_event("plan streaming", event)

  defp humanize_codex_event(%Event{method: "item/reasoning/summaryTextDelta"} = event),
    do: humanize_streaming_event("reasoning summary streaming", event)

  defp humanize_codex_event(%Event{method: "item/reasoning/summaryPartAdded"} = event),
    do: humanize_streaming_event("reasoning summary section added", event)

  defp humanize_codex_event(%Event{method: "item/reasoning/textDelta"} = event),
    do: humanize_streaming_event("reasoning text streaming", event)

  defp humanize_codex_event(%Event{method: "item/commandExecution/outputDelta"} = event),
    do: humanize_streaming_event("command output streaming", event)

  defp humanize_codex_event(%Event{method: "item/fileChange/outputDelta"} = event),
    do: humanize_streaming_event("file change output streaming", event)

  defp humanize_codex_event(%Event{method: "item/commandExecution/requestApproval"} = event) do
    command = extract_command(event)

    if is_binary(command) do
      "command approval requested (#{command})"
    else
      "command approval requested"
    end
  end

  defp humanize_codex_event(%Event{method: "item/fileChange/requestApproval", change_count: change_count}) do
    if is_integer(change_count) and change_count > 0 do
      "file change approval requested (#{change_count} files)"
    else
      "file change approval requested"
    end
  end

  defp humanize_codex_event(%Event{method: "item/tool/requestUserInput", question: question}) do
    if is_binary(question) and String.trim(question) != "" do
      "tool requires user input: #{inline_text(question)}"
    else
      "tool requires user input"
    end
  end

  defp humanize_codex_event(%Event{method: "tool/requestUserInput"} = event),
    do: humanize_codex_event(%{event | method: "item/tool/requestUserInput"})

  defp humanize_codex_event(%Event{method: "mcpServer/elicitation/request", raw: payload}), do: ToolMethods.mcp_elicitation(payload)
  defp humanize_codex_event(%Event{method: "mcp/elicitation/request", raw: payload}), do: ToolMethods.mcp_elicitation(payload)

  defp humanize_codex_event(%Event{method: "account/updated", auth_mode: auth_mode}) do
    "account updated (auth #{auth_mode || "unknown"})"
  end

  defp humanize_codex_event(%Event{method: "account/rateLimits/updated", rate_limits: rate_limits}) do
    "rate limits updated: #{MessageUsageFormatter.format_rate_limits_summary(rate_limits)}"
  end

  defp humanize_codex_event(%Event{method: "account/chatgptAuthTokens/refresh"}), do: "account auth token refresh requested"

  defp humanize_codex_event(%Event{method: "item/tool/call", raw: payload}), do: ToolMethods.dynamic_tool_call(payload)

  defp humanize_codex_event(%Event{method: <<"codex/event/", suffix::binary>>, raw: payload}) do
    WrapperEvents.humanize(suffix, payload)
  end

  defp humanize_codex_event(%Event{method: method, message_type: msg_type}) do
    if is_binary(msg_type) do
      "#{method} (#{msg_type})"
    else
      method
    end
  end

  defp humanize_item_lifecycle(state, %Event{} = event) do
    item_type = humanize_item_type(event.item_type)

    details =
      []
      |> append_if_present(short_id(event.item_id))
      |> append_if_present(humanize_status(event.item_status))

    detail_suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"
    "item #{state}: #{item_type}#{detail_suffix}"
  end

  defp humanize_streaming_event(label, event) do
    case extract_delta_preview(event) do
      nil -> label
      preview -> "#{label}: #{preview}"
    end
  end

  defp extract_delta_preview(%Event{delta: delta}) do
    case delta do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: inline_text(trimmed)

      _ ->
        nil
    end
  end

  defp extract_command(%Event{command: command}), do: normalize_command(command)

  defp normalize_command(%{} = command) do
    binary_command = SymphonyElixir.Payload.get_any(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = SymphonyElixir.Payload.get_any(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: inline_text(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> inline_text()
    else
      nil
    end
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

  defp humanize_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_status(_status), do: nil

  defp short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: nil

  defp append_if_present(list, value) when is_binary(value) and value != "", do: list ++ [value]
  defp append_if_present(list, _value), do: list

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace(
      "
",
      " "
    )
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp inline_text(other), do: other |> to_string() |> inline_text()

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value
end
