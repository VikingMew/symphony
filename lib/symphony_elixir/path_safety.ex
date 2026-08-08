defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @type canonical_root :: {Path.t(), Path.t()}
  @type strict_descendant_classification ::
          {:inside, Path.t()}
          | {:exact_root, Path.t()}
          | {:symlink_escape, Path.t()}
          | :outside

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  @spec classify_strict_descendant(Path.t(), Path.t(), [canonical_root()]) ::
          strict_descendant_classification()
  def classify_strict_descendant(canonical_path, expanded_path, roots)
      when is_binary(canonical_path) and is_binary(expanded_path) and is_list(roots) do
    exact_root =
      Enum.find(roots, fn {_expanded_root, canonical_root} ->
        canonical_path == canonical_root
      end)

    matching_root =
      Enum.find(roots, fn {_expanded_root, canonical_root} ->
        strictly_inside?(canonical_path, canonical_root)
      end)

    symlink_root =
      Enum.find(roots, fn {expanded_root, _canonical_root} ->
        strictly_inside?(expanded_path, expanded_root)
      end)

    cond do
      exact_root ->
        {_expanded_root, canonical_root} = exact_root
        {:exact_root, canonical_root}

      matching_root ->
        {_expanded_root, canonical_root} = matching_root
        {:inside, canonical_root}

      symlink_root ->
        {_expanded_root, canonical_root} = symlink_root
        {:symlink_escape, canonical_root}

      true ->
        :outside
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)
          resolve_segments(target_root, [], target_segments ++ rest)
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end

  defp strictly_inside?(path, root) do
    path != root and String.starts_with?(path <> "/", root <> "/")
  end
end
