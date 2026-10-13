defmodule SymphonyElixir.AgentCodeNCheck.BaselineLocations do
  @moduledoc false

  @location ~r{((?:lib|test)/[^|,:;@]+):([0-9]+)}
  @location_list ~r{(?:lib|test)/[^|,:;@]+:[0-9]+(?:,(?:lib|test)/[^|,:;@]+:[0-9]+)*}
  @hunk ~r/^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@/m

  @spec relocate_baseline(String.t(), String.t(), [String.t()], [String.t()] | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def relocate_baseline(root, revision, rows, current_rows) do
    with {changed, 0} <- System.cmd("git", ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", revision, "--", "lib", "test"], cd: root, stderr_to_stdout: true),
         {:ok, hunks} <- load_location_hunks(root, revision, String.split(changed, <<0>>, trim: true)),
         {:ok, relocated} <- relocation_rows(root, revision, rows, current_rows, hunks) do
      {:ok, Enum.sort(relocated)}
    else
      {output, status} when is_integer(status) -> {:error, "baseline.location_diff: git exited #{status}: #{String.trim(output)}"}
      {:error, _reason} = error -> error
    end
  end

  defp relocation_rows(_root, _revision, rows, nil, hunks) do
    {:ok, Enum.flat_map(rows, &relocate_finding(&1, hunks))}
  end

  defp relocation_rows(root, revision, rows, current_rows, hunks) do
    exact_rows = Enum.flat_map(rows, &relocate_finding(&1, hunks))

    with {:ok, base_declarations} <- load_declaration_heads(root, revision, rows),
         {:ok, current_declarations} <- load_declaration_heads(root, nil, current_rows) do
      moved_rows =
        Enum.filter(current_rows -- exact_rows, fn current_row ->
          Enum.any?(rows, &relocation_match?(&1, current_row, base_declarations, current_declarations))
        end)

      {:ok, Enum.uniq(exact_rows ++ moved_rows)}
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

  defp relocation_match?("N-05|" <> _rest, _current, _base_declarations, _current_declarations), do: false

  defp relocation_match?(base, current, base_declarations, current_declarations) do
    base_identities = row_declaration_heads(base, base_declarations)
    current_identities = row_declaration_heads(current, current_declarations)

    relocation_key(base) == relocation_key(current) and
      current_identities != [] and
      head_multiset_subset?(current_identities, base_identities)
  end

  defp relocation_key(row), do: row |> String.split("|") |> Enum.take(3)

  defp row_declaration_heads(row, declarations) do
    Regex.scan(@location, row, capture: :all_but_first)
    |> Enum.flat_map(fn [path, line] -> Map.get(declarations, {path, String.to_integer(line)}, []) end)
  end

  defp head_multiset_subset?(current, base) do
    current_counts = Enum.frequencies(current)
    base_counts = Enum.frequencies(base)
    Enum.all?(current_counts, fn {identity, count} -> count <= Map.get(base_counts, identity, 0) end)
  end

  defp load_declaration_heads(root, revision, rows) do
    rows
    |> Enum.flat_map(&Regex.scan(@location, &1, capture: :all_but_first))
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, declarations} ->
      case revision_declaration_heads(root, revision, path) do
        {:ok, indexed} ->
          {:cont, {:ok, Map.merge(declarations, indexed)}}

        {:error, reason} ->
          {:halt, {:error, "baseline.declaration_index: #{path}: #{inspect(reason)}"}}
      end
    end)
  end

  defp revision_declaration_heads(root, revision, path) do
    with {:ok, source} <- read_revision_source(root, revision, path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {:ok, index_declaration_heads(ast, path, %{})}
    end
  end

  defp read_revision_source(root, nil, path), do: File.read(Path.join(root, path))

  defp read_revision_source(root, revision, path) do
    case System.cmd("git", ["show", "#{revision}:#{path}"], cd: root, stderr_to_stdout: true) do
      {source, 0} -> {:ok, source}
      {_output, _status} -> {:ok, ""}
    end
  end

  defp index_declaration_heads({:defmodule, meta, [alias_ast, body]}, path, declarations) do
    declarations = put_declaration_head(declarations, path, meta, {:module, Macro.to_string(alias_ast)})
    index_declaration_heads(extract_keyword_body(body), path, declarations)
  end

  defp index_declaration_heads({kind, meta, [head, body]}, path, declarations) when kind in [:def, :defp] do
    declarations = put_declaration_head(declarations, path, meta, {kind, head_arity(head), Macro.to_string(head)})
    index_declaration_heads(extract_keyword_body(body), path, declarations)
  end

  defp index_declaration_heads({:@, meta, [{kind, _, [type_ast]}]}, path, declarations) when kind in [:type, :opaque] do
    declarations = put_declaration_head(declarations, path, meta, {kind, Macro.to_string(extract_type_head(type_ast))})
    index_declaration_heads(type_ast, path, declarations)
  end

  defp index_declaration_heads({_, _, args}, path, declarations) when is_list(args),
    do: index_declaration_heads(args, path, declarations)

  defp index_declaration_heads(list, path, declarations) when is_list(list) do
    Enum.reduce(list, declarations, &index_declaration_heads(&1, path, &2))
  end

  defp index_declaration_heads(_node, _path, declarations), do: declarations

  defp put_declaration_head(declarations, path, meta, identity) do
    Map.update(declarations, {path, Keyword.fetch!(meta, :line)}, [identity], &[identity | &1])
  end

  defp extract_keyword_body(body) when is_list(body), do: Keyword.get(body, :do)
  defp extract_keyword_body(_body), do: nil

  defp head_arity({:when, _, [head | _guards]}), do: head_arity(head)
  defp head_arity({_name, _, args}) when is_list(args), do: length(args)
  defp head_arity({_name, _, nil}), do: 0

  defp extract_type_head({:"::", _, [head, _definition]}), do: head
  defp extract_type_head(head), do: head
end
