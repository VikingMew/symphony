defmodule SymphonyElixir.Codex.MessageUsageFormatter do
  @moduledoc """
  Usage and rate-limit formatting helpers for Codex message humanization.
  """

  @spec format_usage_counts(term()) :: String.t() | nil
  def format_usage_counts(usage) when is_map(usage) do
    input =
      parse_integer(
        SymphonyElixir.Payload.get_any(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          "promptTokens",
          :promptTokens
        ])
      )

    output =
      parse_integer(
        SymphonyElixir.Payload.get_any(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "outputTokens",
          :outputTokens,
          "completionTokens",
          :completionTokens
        ])
      )

    total =
      parse_integer(
        SymphonyElixir.Payload.get_any(usage, [
          "total_tokens",
          :total_tokens,
          "total",
          :total,
          "totalTokens",
          :totalTokens
        ])
      )

    parts =
      []
      |> append_usage_part("in", input)
      |> append_usage_part("out", output)
      |> append_usage_part("total", total)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, ", ")
    end
  end

  def format_usage_counts(_usage), do: nil

  @spec format_rate_limits_summary(term()) :: String.t()
  def format_rate_limits_summary(nil), do: "n/a"

  def format_rate_limits_summary(rate_limits) when is_map(rate_limits) do
    primary = SymphonyElixir.Payload.get_any(rate_limits, ["primary", :primary])
    secondary = SymphonyElixir.Payload.get_any(rate_limits, ["secondary", :secondary])

    primary_text = format_rate_limit_bucket_summary(primary)
    secondary_text = format_rate_limit_bucket_summary(secondary)

    cond do
      primary_text != nil and secondary_text != nil -> "primary #{primary_text}; secondary #{secondary_text}"
      primary_text != nil -> "primary #{primary_text}"
      secondary_text != nil -> "secondary #{secondary_text}"
      true -> "n/a"
    end
  end

  def format_rate_limits_summary(_rate_limits), do: "n/a"

  defp append_usage_part(parts, _label, value) when not is_integer(value), do: parts
  defp append_usage_part(parts, label, value), do: parts ++ ["#{label} #{SymphonyElixir.NumberFormat.grouped_integer(value)}"]

  defp format_rate_limit_bucket_summary(bucket) when is_map(bucket) do
    used_percent = SymphonyElixir.Payload.get_any(bucket, ["used_percent", :used_percent, "usedPercent", :usedPercent])
    window_mins = SymphonyElixir.Payload.get_any(bucket, ["window_duration_mins", :window_duration_mins, "windowDurationMins", :windowDurationMins])

    cond do
      is_number(used_percent) and is_integer(window_mins) -> "#{used_percent}% / #{window_mins}m"
      is_number(used_percent) -> "#{used_percent}% used"
      true -> nil
    end
  end

  defp format_rate_limit_bucket_summary(_bucket), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
