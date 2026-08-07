defmodule SymphonyElixir.StateName do
  @moduledoc """
  Shared Linear workflow state-name normalization.
  """

  @spec normalize(term()) :: String.t()
  def normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  def normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  @spec blank_string?(term()) :: boolean()
  def blank_string?(nil), do: true
  def blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  def blank_string?(_value), do: false
end
