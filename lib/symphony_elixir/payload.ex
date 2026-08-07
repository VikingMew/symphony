defmodule SymphonyElixir.Payload do
  @moduledoc """
  Helpers for mixed atom/string keyed external payloads.
  """

  @spec get_any(map(), [atom() | String.t()], term()) :: term()
  def get_any(map, keys, default \\ nil)

  def get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, default, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, default}
      end
    end)
  end

  def get_any(_map, _keys, default), do: default

  @spec get_path(map(), [atom() | String.t() | [atom() | String.t()]], term()) :: term()
  def get_path(map, path, default \\ nil)

  def get_path(map, path, default) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn keys, acc ->
      case get_any(acc, List.wrap(keys), :__missing__) do
        :__missing__ -> {:halt, default}
        value -> {:cont, value}
      end
    end)
  end

  def get_path(_map, _path, default), do: default
end
