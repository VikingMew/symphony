defmodule SymphonyElixir.Redaction do
  @moduledoc """
  Shared sanitization helpers for logs and persisted diagnostics.
  """

  @spec credentials(term()) :: String.t()
  def credentials(output) do
    output
    |> IO.iodata_to_binary()
    |> String.replace(~r/(?i)(authorization\s*[:=]\s*)(bearer|basic)?\s*[^\s,;]+/, "\\1[REDACTED]")
    |> String.replace(~r/(?i)((?:api[_-]?key|token|secret)["']?\s*,\s*["'])[^"']+(["'])/, "\\1[REDACTED]\\2")
    |> String.replace(~r/(?i)((?:api[_-]?key|token|secret)\s*[:=]\s*)[^\s,;\]\}]+/, "\\1[REDACTED]")
  end

  @spec payload(term(), pos_integer()) :: term()
  def payload(value, max_string_bytes) when is_integer(max_string_bytes) and max_string_bytes > 0 do
    scrub_payload(value, max_string_bytes)
  end

  @spec sensitive_env_values(String.t(), [String.t()]) :: String.t()
  def sensitive_env_values(output, env_names) when is_binary(output) and is_list(env_names) do
    Enum.reduce(env_names, output, fn name, acc ->
      case System.get_env(name) do
        value when value not in [nil, ""] -> String.replace(acc, value, "[REDACTED #{name}]")
        _ -> acc
      end
    end)
  end

  @spec ansi_and_control(String.t()) :: String.t()
  def ansi_and_control(value) when is_binary(value) do
    value
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
  end

  @spec bounded(term(), pos_integer()) :: String.t()
  def bounded(output, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    output
    |> credentials()
    |> truncate_bytes(max_bytes)
  end

  @spec uri_userinfo(String.t()) :: String.t()
  def uri_userinfo(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" ->
        String.replace(value, userinfo <> "@", "[REDACTED]@", global: false)

      _ ->
        value
    end
  end

  defp truncate_bytes(value, max_bytes) do
    if byte_size(value) <= max_bytes do
      value
    else
      binary_part(value, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp scrub_payload(%DateTime{} = value, _max_string_bytes), do: DateTime.to_iso8601(value)

  defp scrub_payload(%{} = payload, max_string_bytes) do
    Map.new(payload, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, scrub_payload(value, max_string_bytes)}
    end)
  end

  defp scrub_payload(value, max_string_bytes) when is_binary(value) do
    value
    |> credentials()
    |> truncate_bytes(max_string_bytes)
  end

  defp scrub_payload(value, max_string_bytes) when is_list(value), do: Enum.map(value, &scrub_payload(&1, max_string_bytes))
  defp scrub_payload(value, _max_string_bytes), do: value

  defp sensitive_key?(key),
    do: key |> to_string() |> String.downcase() |> String.contains?(["token", "secret", "authorization", "api_key", "cookie"])
end
