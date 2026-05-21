defmodule SymphonyElixir.Payload do
  @moduledoc """
  Helpers for mixed atom/string keyed external payloads.
  """

  def get_any(map, keys, default \\ nil)

  @spec get_any(map(), [atom() | String.t()], term()) :: term()
  def get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> false
      end
    end)
  end

  def get_any(_map, _keys, default), do: default

  def get_path(map, path, default \\ nil)

  @spec get_path(map(), [[atom() | String.t()]], term()) :: term()
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
