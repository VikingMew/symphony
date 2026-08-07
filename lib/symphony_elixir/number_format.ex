defmodule SymphonyElixir.NumberFormat do
  @moduledoc """
  Small presentation helpers for numeric values.
  """

  @spec grouped_integer(integer()) :: String.t()
  def grouped_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    sign <> grouped_unsigned(unsigned)
  end

  defp grouped_unsigned(value) do
    value
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
