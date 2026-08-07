defmodule SymphonyElixir.Text do
  @moduledoc """
  Shared text normalization helpers.
  """

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: false

  @spec blankish?(term()) :: boolean()
  def blankish?(nil), do: true
  def blankish?(value), do: String.trim(to_string(value)) == ""

  @spec blank_as_nil(term()) :: String.t() | nil
  def blank_as_nil(value) do
    value = String.trim(to_string(value || ""))
    if value == "", do: nil, else: value
  end
end
