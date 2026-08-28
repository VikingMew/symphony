defmodule SymphonyElixir.Worker.Cleanup do
  @moduledoc "Age-bounded cleanup that preserves active lease directories."

  alias SymphonyElixir.Worker.Paths

  @spec sweep(Path.t(), [Path.t()], MapSet.t(Path.t()), non_neg_integer(), DateTime.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def sweep(root, targets, active, max_age_seconds, now) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, removed} ->
      sweep_target(root, target, active, max_age_seconds, now, removed)
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end
  end

  defp sweep_target(root, target, active, max_age_seconds, now, removed) do
    with false <- MapSet.member?(active, target),
         {:ok, stat} <- File.stat(target, time: :posix),
         true <- DateTime.to_unix(now) - stat.mtime > max_age_seconds do
      remove_target(root, target, removed)
    else
      _ -> {:cont, {:ok, removed}}
    end
  end

  defp remove_target(root, target, removed) do
    case Paths.remove_contained(root, target) do
      :ok -> {:cont, {:ok, [target | removed]}}
      error -> {:halt, error}
    end
  end

  @spec remove_expired(Path.t(), MapSet.t(Path.t()), non_neg_integer(), DateTime.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def remove_expired(root, active, max_age_seconds, now) do
    with {:ok, entries} <- File.ls(root) do
      sweep(root, Enum.map(entries, &Path.join(root, &1)), active, max_age_seconds, now)
    end
  end

  @spec descendants_at_depth(Path.t(), pos_integer()) :: [Path.t()]
  def descendants_at_depth(root, depth), do: descend([root], depth)

  @spec evict_cache(Path.t(), non_neg_integer(), non_neg_integer(), DateTime.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def evict_cache(root, max_bytes, max_age_seconds, now) do
    with {:ok, entries} <- File.ls(root) do
      candidates =
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.map(fn path -> {path, path_size(path), modified_at(path)} end)
        |> Enum.sort_by(fn {_path, _size, mtime} -> mtime end)

      total = Enum.reduce(candidates, 0, fn {_path, size, _mtime}, acc -> acc + size end)

      candidates
      |> Enum.reduce_while({:ok, [], total}, fn {target, size, mtime}, {:ok, removed, remaining} ->
        evict_target(root, target, size, mtime, removed, remaining, {max_bytes, max_age_seconds, now})
      end)
      |> case do
        {:ok, removed, _remaining} -> {:ok, Enum.reverse(removed)}
        error -> error
      end
    end
  end

  defp evict_target(root, target, size, mtime, removed, remaining, {max_bytes, max_age_seconds, now}) do
    expired = DateTime.to_unix(now) - mtime > max_age_seconds

    if expired or remaining > max_bytes do
      evict_contained(root, target, size, removed, remaining)
    else
      {:cont, {:ok, removed, remaining}}
    end
  end

  defp evict_contained(root, target, size, removed, remaining) do
    case Paths.remove_contained(root, target) do
      :ok -> {:cont, {:ok, [target | removed], max(remaining - size, 0)}}
      error -> {:halt, error}
    end
  end

  defp descend(paths, 0), do: paths

  defp descend(paths, depth) do
    paths
    |> Enum.flat_map(fn path ->
      case File.ls(path) do
        {:ok, entries} -> entries |> Enum.map(&Path.join(path, &1)) |> Enum.filter(&File.dir?/1)
        {:error, _reason} -> []
      end
    end)
    |> descend(depth - 1)
  end

  defp path_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        directory_size(path)

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _reason} ->
        0
    end
  end

  defp directory_size(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.reduce(entries, 0, fn entry, acc -> acc + path_size(Path.join(path, entry)) end)
      {:error, _reason} -> 0
    end
  end

  defp modified_at(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end
end
