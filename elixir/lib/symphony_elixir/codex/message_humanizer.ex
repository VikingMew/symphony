defmodule SymphonyElixir.Codex.MessageHumanizer do
  @moduledoc """
  Pure formatter facade for compact, operator-facing Codex protocol and event messages.
  """

  alias SymphonyElixir.Codex.MessageHumanizer.Methods

  @doc false
  @spec humanize_codex_message(term()) :: String.t()
  def humanize_codex_message(nil), do: "no codex message yet"

  def humanize_codex_message(%{event: event, message: message}) do
    payload = unwrap_codex_message_payload(message)

    (humanize_codex_event(event, message, payload) || humanize_codex_payload(payload))
    |> truncate(140)
  end

  def humanize_codex_message(%{message: message}) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  def humanize_codex_message(message) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> truncate(140)
  end

  defp humanize_codex_event(:session_started, _message, payload) do
    session_id = SymphonyElixir.Payload.get_any(payload, ["session_id", :session_id])
    if is_binary(session_id), do: "session started (#{session_id})", else: "session started"
  end

  defp humanize_codex_event(:turn_input_required, _message, payload) do
    case SymphonyElixir.Payload.get_any(payload, ["method", :method]) do
      method when method in ["mcpServer/elicitation/request", "mcp/elicitation/request"] -> Methods.humanize_mcp(payload)
      _ -> "turn blocked: waiting for user input"
    end
  end

  defp humanize_codex_event(:approval_auto_approved, message, payload) do
    method =
      SymphonyElixir.Payload.get_any(payload, ["method", :method]) ||
        SymphonyElixir.Payload.get_path(message, ["payload", "method"]) ||
        SymphonyElixir.Payload.get_path(message, [:payload, :method])

    decision = SymphonyElixir.Payload.get_any(message, ["decision", :decision])

    base = if is_binary(method), do: "#{Methods.humanize(method, payload)} (auto-approved)", else: "approval request auto-approved"
    if is_binary(decision), do: "#{base}: #{decision}", else: base
  end

  defp humanize_codex_event(:tool_input_auto_answered, message, payload) do
    answer = SymphonyElixir.Payload.get_any(message, ["answer", :answer])
    base = "#{Methods.humanize("item/tool/requestUserInput", payload)} (auto-answered)"
    if is_binary(answer), do: "#{base}: #{inline_text(answer)}", else: base
  end

  defp humanize_codex_event(:tool_call_completed, _message, payload), do: Methods.humanize_dynamic_tool("dynamic tool call completed", payload)
  defp humanize_codex_event(:tool_call_failed, _message, payload), do: Methods.humanize_dynamic_tool("dynamic tool call failed", payload)
  defp humanize_codex_event(:unsupported_tool_call, _message, payload), do: Methods.humanize_dynamic_tool("unsupported dynamic tool call rejected", payload)
  defp humanize_codex_event(:turn_ended_with_error, message, _payload), do: "turn ended with error: #{format_reason(message)}"
  defp humanize_codex_event(:startup_failed, message, _payload), do: "startup failed: #{format_reason(message)}"
  defp humanize_codex_event(:turn_failed, _message, payload), do: Methods.humanize("turn/failed", payload)
  defp humanize_codex_event(:turn_cancelled, _message, _payload), do: "turn cancelled"
  defp humanize_codex_event(:malformed, _message, _payload), do: "malformed JSON event from codex"
  defp humanize_codex_event(_event, _message, _payload), do: nil

  defp unwrap_codex_message_payload(%{} = message) do
    cond do
      is_binary(SymphonyElixir.Payload.get_any(message, ["method", :method])) -> message
      is_binary(SymphonyElixir.Payload.get_any(message, ["session_id", :session_id])) -> message
      is_binary(SymphonyElixir.Payload.get_any(message, ["reason", :reason])) -> message
      true -> SymphonyElixir.Payload.get_any(message, ["payload", :payload]) || message
    end
  end

  defp unwrap_codex_message_payload(message), do: message

  defp humanize_codex_payload(%{} = payload) do
    case SymphonyElixir.Payload.get_any(payload, ["method", :method]) do
      method when is_binary(method) ->
        Methods.humanize(method, payload)

      _ ->
        cond do
          is_binary(SymphonyElixir.Payload.get_any(payload, ["session_id", :session_id])) ->
            "session started (#{SymphonyElixir.Payload.get_any(payload, ["session_id", :session_id])})"

          match?(%{"error" => _}, payload) ->
            "error: #{format_error_value(Map.get(payload, "error"))}"

          true ->
            payload
            |> inspect(pretty: true, limit: 30)
            |> String.replace("\n", " ")
            |> sanitize_ansi_and_control_bytes()
            |> String.trim()
        end
    end
  end

  defp humanize_codex_payload(payload) when is_binary(payload) do
    payload |> String.replace("\n", " ") |> sanitize_ansi_and_control_bytes() |> String.trim()
  end

  defp humanize_codex_payload(payload) do
    payload |> inspect(pretty: true, limit: 20) |> String.replace("\n", " ") |> sanitize_ansi_and_control_bytes() |> String.trim()
  end

  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: inspect(error, limit: 10)

  defp format_reason(message) when is_map(message) do
    case SymphonyElixir.Payload.get_any(message, ["reason", :reason]) do
      nil -> message |> inspect(limit: 10) |> inline_text()
      reason -> format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)
  defp sanitize_ansi_and_control_bytes(value) when is_binary(value), do: SymphonyElixir.Redaction.ansi_and_control(value)

  defp inline_text(text) when is_binary(text) do
    text |> String.replace("\n", " ") |> String.replace(~r/\s+/, " ") |> String.trim() |> truncate(80)
  end

  defp truncate(value, max) when byte_size(value) > max, do: value |> String.slice(0, max) |> Kernel.<>("...")
  defp truncate(value, _max), do: value
end
