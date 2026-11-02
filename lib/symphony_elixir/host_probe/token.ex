defmodule SymphonyElixir.HostProbe.Token do
  @moduledoc "Loads the host-probe bearer token from an owner-only regular file."

  @spec load_bearer(Path.t()) ::
          {:ok, String.t()} | {:error, :missing_token_file | :invalid_token_file_mode | :empty_token_file}
  def load_bearer(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         :ok <- owner_only_regular_file(stat),
         {:ok, contents} <- File.read(path),
         token <- String.trim(contents),
         true <- token != "" do
      {:ok, token}
    else
      {:error, :invalid_token_file_mode} -> {:error, :invalid_token_file_mode}
      {:error, :enoent} -> {:error, :missing_token_file}
      {:error, _reason} -> {:error, :missing_token_file}
      false -> {:error, :empty_token_file}
    end
  end

  defp owner_only_regular_file(%File.Stat{type: :regular, mode: mode}) do
    if Bitwise.band(mode, 0o777) == 0o600, do: :ok, else: {:error, :invalid_token_file_mode}
  end

  defp owner_only_regular_file(_stat), do: {:error, :invalid_token_file_mode}
end
