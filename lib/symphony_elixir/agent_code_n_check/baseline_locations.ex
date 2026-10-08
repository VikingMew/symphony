defmodule SymphonyElixir.AgentCodeNCheck.BaselineLocations do
  @moduledoc false

  @location ~r{((?:lib|test)/[^|,:;@]+):([0-9]+)}
  @location_list ~r{(?:lib|test)/[^|,:;@]+:[0-9]+(?:,(?:lib|test)/[^|,:;@]+:[0-9]+)*}
  @hunk ~r/^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@/m

  @spec relocate_baseline(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def relocate_baseline(root, revision, rows) do
    with {changed, 0} <- System.cmd("git", ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", revision, "--", "lib", "test"], cd: root, stderr_to_stdout: true),
         {:ok, hunks} <- load_location_hunks(root, revision, String.split(changed, <<0>>, trim: true)) do
      relocated = Enum.flat_map(rows, &relocate_finding(&1, hunks))
      {:ok, Enum.sort(relocated)}
    else
      {output, status} when is_integer(status) -> {:error, "baseline.location_diff: git exited #{status}: #{String.trim(output)}"}
      {:error, _reason} = error -> error
    end
  end

  defp load_location_hunks(root, revision, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, hunks} ->
      case System.cmd("git", ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=0", revision, "--", path], cd: root, stderr_to_stdout: true) do
        {diff, 0} ->
          ranges =
            Regex.scan(@hunk, diff, capture: :all_but_first)
            |> Enum.map(&parse_location_hunk/1)

          {:cont, {:ok, Map.put(hunks, path, ranges)}}

        {output, status} ->
          {:halt, {:error, "baseline.location_diff: git exited #{status}: #{String.trim(output)}"}}
      end
    end)
  end

  defp parse_location_hunk([start | counts]) do
    [removed, added] = Enum.take(counts ++ ["", ""], 2)
    {String.to_integer(start), hunk_count(removed), hunk_count(added)}
  end

  defp hunk_count(""), do: 1
  defp hunk_count(count), do: String.to_integer(count)

  defp relocate_finding("N-05|" <> _rest = row, hunks) do
    [rule, kind, path | details] = String.split(row, "|")

    moved =
      Enum.map(details, fn detail ->
        Regex.replace(~r/@(\d+)/, detail, fn _match, line -> "@" <> relocate_line(hunks, path, line) end)
      end)

    keep_mapped_finding(Enum.join([rule, kind, path | moved], "|"))
  end

  defp relocate_finding(row, hunks) do
    moved = Regex.replace(@location, row, fn _match, path, line -> path <> ":" <> relocate_line(hunks, path, line) end)
    sorted = Regex.replace(@location_list, moved, fn locations -> locations |> String.split(",") |> Enum.sort() |> Enum.join(",") end)
    keep_mapped_finding(sorted)
  end

  defp keep_mapped_finding(row) do
    if String.contains?(row, "<changed-declaration>"), do: [], else: [row]
  end

  defp relocate_line(hunks, path, text) do
    line = String.to_integer(text)

    Enum.reduce_while(Map.get(hunks, path, []), line, fn {start, removed, added}, moved ->
      cond do
        removed > 0 and line >= start and line < start + removed -> {:halt, "<changed-declaration>"}
        (removed == 0 and line > start) or (removed > 0 and line >= start + removed) -> {:cont, moved + added - removed}
        true -> {:cont, moved}
      end
    end)
    |> to_string()
  end
end
