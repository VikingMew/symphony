defmodule SymphonyElixir.Codex.TokenUsage do
  @moduledoc """
  Extracts absolute Codex token usage from app-server and wrapper payloads.
  """

  alias SymphonyElixir.Codex.Protocol

  @zero %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  @spec zero() :: map()
  def zero, do: @zero

  @spec absolute_usage(map()) :: map()
  def absolute_usage(update) when is_map(update) do
    event = Protocol.normalize_event(update)

    normalize(%{
      input_tokens: event.input_tokens,
      output_tokens: event.output_tokens,
      total_tokens: event.total_tokens
    })
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

  defp payload_get(payload, fields) when is_list(fields), do: Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  defp map_integer_value(payload, field) when is_map(payload), do: payload |> Map.get(field) |> integer_like()
  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
