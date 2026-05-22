defmodule SymphonyElixir.Codex.MessageHumanizer.ToolMethods do
  @moduledoc false

  @spec dynamic_tool_call(map()) :: String.t()
  def dynamic_tool_call(payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) and tool != "" -> "dynamic tool call requested (#{tool})"
      _ -> "dynamic tool call requested"
    end
  end

  @spec mcp_elicitation(map()) :: String.t()
  def mcp_elicitation(payload) do
    details =
      [
        {"server", extract_mcp_server_name(payload)},
        {"tool", extract_mcp_tool_name(payload)},
        {"prompt", extract_mcp_elicitation_prompt(payload)}
      ]
      |> Enum.flat_map(fn
        {_label, nil} -> []
        {label, value} -> ["#{label}: #{inline_text(value)}"]
      end)

    case details do
      [] -> "MCP elicitation requested"
      _ -> "MCP elicitation requested (#{Enum.join(details, ", ")})"
    end
  end

  @spec dynamic_tool_event(String.t(), map()) :: String.t()
  def dynamic_tool_event(base, payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) and tool != "" -> "#{base} (#{tool})"
      _ -> base
    end
  end

  defp dynamic_tool_name(payload) do
    [
      ["params", "tool"],
      ["params", "name"],
      [:params, :tool],
      [:params, :name]
    ]
    |> first_binary_path(payload)
  end

  defp extract_mcp_server_name(payload) do
    first_binary_path(
      [
        ["params", "server"],
        [:params, :server],
        ["params", "serverName"],
        [:params, :serverName],
        ["params", "server_name"],
        [:params, :server_name],
        ["params", "mcpServer"],
        [:params, :mcpServer],
        ["params", "mcp_server"],
        [:params, :mcp_server],
        ["params", "server", "name"],
        [:params, :server, :name],
        ["params", "request", "server"],
        [:params, :request, :server],
        ["params", "request", "serverName"],
        [:params, :request, :serverName]
      ],
      payload
    )
  end

  defp extract_mcp_tool_name(payload) do
    first_binary_path(
      [
        ["params", "tool"],
        [:params, :tool],
        ["params", "toolName"],
        [:params, :toolName],
        ["params", "tool_name"],
        [:params, :tool_name],
        ["params", "name"],
        [:params, :name],
        ["params", "request", "tool"],
        [:params, :request, :tool],
        ["params", "request", "toolName"],
        [:params, :request, :toolName],
        ["params", "item", "tool"],
        [:params, :item, :tool],
        ["params", "item", "name"],
        [:params, :item, :name]
      ],
      payload
    )
  end

  defp extract_mcp_elicitation_prompt(payload) do
    first_binary_path(
      [
        ["params", "prompt"],
        [:params, :prompt],
        ["params", "message"],
        [:params, :message],
        ["params", "question"],
        [:params, :question],
        ["params", "request", "prompt"],
        [:params, :request, :prompt],
        ["params", "request", "message"],
        [:params, :request, :message],
        ["params", "elicitation", "prompt"],
        [:params, :elicitation, :prompt],
        ["params", "elicitation", "message"],
        [:params, :elicitation, :message]
      ],
      payload
    )
  end

  defp first_binary_path(paths, payload) do
    Enum.find_value(paths, fn path ->
      payload
      |> SymphonyElixir.Payload.get_path(path)
      |> non_blank_binary()
    end)
  end

  defp non_blank_binary(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_blank_binary(_value), do: nil

  defp inline_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp inline_text(value), do: inspect(value)
end
