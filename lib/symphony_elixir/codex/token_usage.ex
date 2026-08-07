defmodule SymphonyElixir.Codex.TokenUsage do
  @moduledoc """
  Extracts absolute Codex token usage from app-server and wrapper payloads.
  """

  alias SymphonyElixir.Payload

  @zero %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  @spec zero() :: map()
  def zero, do: @zero

  @spec absolute_usage(map()) :: map()
  def absolute_usage(update) when is_map(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    (Enum.find_value(payloads, &absolute_usage_from_payload/1) ||
       Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
       @zero)
    |> normalize()
  end

  def absolute_usage(_update), do: @zero

  @spec get(map(), :input | :output | :total) :: non_neg_integer()
  def get(usage, :input) do
    payload_get(usage, [
      "input_tokens",
      "prompt_tokens",
      :input_tokens,
      :prompt_tokens,
      :input,
      "promptTokens",
      :promptTokens,
      "inputTokens",
      :inputTokens
    ]) || 0
  end

  def get(usage, :output) do
    payload_get(usage, [
      "output_tokens",
      "completion_tokens",
      :output_tokens,
      :completion_tokens,
      :output,
      :completion,
      "outputTokens",
      :outputTokens,
      "completionTokens",
      :completionTokens
    ]) || 0
  end

  def get(usage, :total) do
    payload_get(usage, ["total_tokens", "total", :total_tokens, :total, "totalTokens", :totalTokens]) || 0
  end

  @spec normalize(map()) :: map()
  def normalize(usage) when is_map(usage) do
    %{
      input_tokens: get(usage, :input),
      output_tokens: get(usage, :output),
      total_tokens: get(usage, :total)
    }
  end

  def normalize(_usage), do: @zero

  defp absolute_usage_from_payload(payload) when is_map(payload) do
    explicit_map_at_paths(payload, [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total],
      ["tokens"],
      [:tokens],
      ["params", "tokens"],
      [:params, :tokens],
      ["params", "total_token_usage"],
      [:params, :total_token_usage],
      ["message", "params", "tokens"],
      [:message, :params, :tokens],
      ["message", "params", "total_token_usage"],
      [:message, :params, :total_token_usage]
    ])
  end

  defp absolute_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Payload.get_any(payload, ["method", :method])

    direct =
      Payload.get_any(payload, ["usage", :usage]) ||
        Payload.get_path(payload, ["params", "usage"]) ||
        Payload.get_path(payload, [:params, :usage])

    if method in ["turn/completed", :turn_completed] and is_map(direct) and token_map?(direct), do: direct
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp explicit_map_at_paths(payload, paths) do
    Enum.find_value(paths, fn path ->
      value = Payload.get_path(payload, path)
      if is_map(value) and token_map?(value), do: value
    end)
  end

  defp token_map?(payload) do
    [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      is_integer(value)
    end)
  end

  defp payload_get(payload, fields) when is_list(fields), do: Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  defp payload_get(payload, field), do: map_integer_value(payload, field)
  defp map_integer_value(payload, field) when is_map(payload), do: payload |> Map.get(field) |> integer_like()
  defp map_integer_value(_payload, _field), do: nil
  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
