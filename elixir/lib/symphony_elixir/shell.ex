defmodule SymphonyElixir.Shell do
  @moduledoc """
  POSIX shell command construction helpers.
  """

  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
