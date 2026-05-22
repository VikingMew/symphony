defmodule SymphonyElixir.WorkspaceDiskGuard do
  @moduledoc """
  Blocks local agent startup when configured workspace roots do not have enough free space.
  """

  alias SymphonyElixir.Workspace.SourcePreparation

  @default_min_free_bytes 1_073_741_824

  @spec check(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def check(settings, opts \\ []) when is_map(settings) do
    min_free_bytes = get_in(settings, [:workspace, :min_free_bytes]) || @default_min_free_bytes
    free_bytes_fun = Keyword.get(opts, :free_bytes_fun, &free_bytes/1)

    if min_free_bytes <= 0 do
      {:ok, %{min_free_bytes: min_free_bytes, free_bytes: :unchecked, root: nil}}
    else
      settings
      |> roots()
      |> Enum.map(&check_root(&1, min_free_bytes, free_bytes_fun))
      |> Enum.find({:ok, nil}, &match?({:error, _}, &1))
      |> normalize_result()
    end
  end

  defp roots(settings) do
    [
      get_in(settings, [:workspace, :root]),
      SourcePreparation.repository_base_root(settings),
      SourcePreparation.worktree_base_root(settings)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp check_root(root, min_free_bytes, free_bytes_fun) do
    case free_bytes_fun.(existing_ancestor(root)) do
      {:ok, free_bytes} when is_integer(free_bytes) and free_bytes >= min_free_bytes ->
        {:ok, %{root: root, free_bytes: free_bytes, min_free_bytes: min_free_bytes}}

      {:ok, free_bytes} when is_integer(free_bytes) ->
        {:error,
         %{
           reason: :low_disk_space,
           root: root,
           free_bytes: free_bytes,
           min_free_bytes: min_free_bytes,
           setting: "Settings / Workflow / Runtime / Minimum free GiB"
         }}

      {:error, reason} ->
        {:error,
         %{
           reason: :disk_space_unavailable,
           root: root,
           detail: inspect(reason),
           min_free_bytes: min_free_bytes,
           setting: "Settings / Workflow / Runtime / Minimum free GiB"
         }}
    end
  end

  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(_), do: {:ok, %{}}

  defp existing_ancestor(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(expanded) -> expanded
      parent = Path.dirname(expanded) -> if(parent == expanded, do: expanded, else: existing_ancestor(parent))
    end
  end

  defp free_bytes(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df_available_kib(output)
      {output, status} -> {:error, {:df_failed, status, output}}
    end
  end

  defp parse_df_available_kib(output) do
    with [_header, row | _] <- String.split(output, "\n", trim: true),
         [_filesystem, _blocks, _used, available | _] <- String.split(row, ~r/\s+/, trim: true),
         {available_kib, ""} <- Integer.parse(available) do
      {:ok, available_kib * 1024}
    else
      _ -> {:error, {:invalid_df_output, output}}
    end
  end
end
