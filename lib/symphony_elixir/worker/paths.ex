defmodule SymphonyElixir.Worker.Paths do
  @moduledoc "Contained worker filesystem layout and deletion checks."

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Worker.Config

  @spec prepare_roots(Config.t()) :: :ok | {:error, term()}
  def prepare_roots(config) do
    Enum.reduce_while([config.workspace_root, config.cache_root, config.log_root], :ok, fn root, :ok ->
      case File.mkdir_p(root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec lease_dir(Config.t(), String.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def lease_dir(config, project_id, task_id, lease_id) do
    contained_join(config.workspace_root, [project_id, task_id, lease_id])
  end

  @spec log_dir(Config.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def log_dir(config, task_id, lease_id), do: contained_join(config.log_root, [task_id, lease_id])

  @spec contained_join(Path.t(), [String.t()]) :: {:ok, Path.t()} | {:error, term()}
  def contained_join(root, segments) do
    with true <- Path.type(root) == :absolute,
         true <- Enum.all?(segments, &safe_segment?/1),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         candidate = Path.join([root | segments]),
         {:ok, canonical_candidate} <- PathSafety.canonicalize(candidate),
         {:inside, ^canonical_root} <-
           PathSafety.classify_strict_descendant(canonical_candidate, Path.expand(candidate), [{Path.expand(root), canonical_root}]) do
      {:ok, canonical_candidate}
    else
      _ -> {:error, :path_escape}
    end
  end

  @spec remove_contained(Path.t(), Path.t()) :: :ok | {:error, term()}
  def remove_contained(root, target) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, canonical_target} <- PathSafety.canonicalize(target),
         {:inside, ^canonical_root} <-
           PathSafety.classify_strict_descendant(canonical_target, Path.expand(target), [{Path.expand(root), canonical_root}]) do
      File.rm_rf(canonical_target)
      |> case do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    else
      _ -> {:error, :path_escape}
    end
  end

  defp safe_segment?(segment), do: is_binary(segment) and segment not in ["", ".", ".."] and Path.basename(segment) == segment
end
