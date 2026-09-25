defmodule SymphonyElixir.Locality do
  @moduledoc false

  @max_file_lines 1_000
  @max_clause_lines 60
  @max_nesting_depth 2
  @max_remote_call_depth 2
  @nesting_forms [:if, :unless, :case, :cond, :fn, :for, :with]
  @required_exception_fields ~w(path identifier lines split owner due)a

  @type config :: %{
          required(:code_extensions) => [String.t()],
          required(:code_basenames) => [String.t()],
          required(:data_paths) => [String.t()],
          required(:generated) => [map()],
          required(:clause_exceptions) => [map()]
        }
  @type violation :: %{required(:path) => String.t(), required(:message) => String.t()}

  @spec config(Path.t()) :: config()
  def config(root \\ File.cwd!()) do
    {value, _binding} = Code.eval_file(Path.join(root, "config/locality.exs"))
    value
  end

  @spec tracked_paths(Path.t()) :: [String.t()]
  def tracked_paths(root \\ File.cwd!()) do
    {output, 0} =
      System.cmd("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], cd: root)

    output
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&File.regular?(Path.join(root, &1)))
    |> Enum.sort()
  end

  @spec check(Path.t(), Date.t()) :: [violation()]
  def check(root \\ File.cwd!(), today \\ Date.utc_today()) do
    paths = tracked_paths(root)
    settings = config(root)

    check_paths(root, paths, settings, today)
  end

  @spec check_paths(Path.t(), [String.t()], config(), Date.t()) :: [violation()]
  def check_paths(root, paths, settings, today) do
    generated_paths = MapSet.new(settings.generated, &Map.get(&1, :path))
    data_paths = MapSet.new(settings.data_paths)

    code_violations =
      paths
      |> Enum.filter(&code_path?(&1, settings))
      |> Enum.reject(&MapSet.member?(data_paths, &1))
      |> Enum.flat_map(fn path ->
        absolute_path = Path.join(root, path)

        if MapSet.member?(generated_paths, path) do
          generated_header_violations(absolute_path, path, settings.generated)
        else
          handwritten_violations(absolute_path, path, settings, today)
        end
      end)

    (manifest_violations(root, paths, settings, today) ++ code_violations)
    |> Enum.sort_by(&{&1.path, &1.message})
  end

  @spec format([violation()]) :: String.t()
  def format([]), do: "Locality check passed.\n"

  def format(violations) do
    details = Enum.map_join(violations, "\n", &"#{&1.path}: #{&1.message}")
    "Locality check failed with #{length(violations)} violation(s):\n#{details}\n"
  end

  defp manifest_violations(root, paths, settings, today) do
    tracked = MapSet.new(paths)

    stale_data =
      settings.data_paths
      |> Enum.reject(&MapSet.member?(tracked, &1))
      |> Enum.map(&violation(&1, "data exclusion does not name a tracked file"))

    generated =
      Enum.flat_map(settings.generated, fn entry ->
        cond do
          Map.keys(entry) |> Enum.sort() != [:path, :source] ->
            [violation(Map.get(entry, :path, "config/locality.exs"), "generated entry requires exactly path and source")]

          not MapSet.member?(tracked, entry.path) ->
            [violation(entry.path, "generated exclusion does not name a tracked file")]

          true ->
            []
        end
      end)

    exceptions =
      Enum.flat_map(
        settings.clause_exceptions,
        &exception_violations(&1, tracked, today, root)
      )

    stale_data ++ generated ++ exceptions
  end

  defp exception_violations(entry, tracked, today, root) do
    missing = Enum.reject(@required_exception_fields, &Map.has_key?(entry, &1))
    path = Map.get(entry, :path, "config/locality.exs")

    cond do
      missing != [] ->
        [violation(path, "clause exception missing fields: #{Enum.join(missing, ", ")}")]

      not MapSet.member?(tracked, path) ->
        [violation(path, "clause exception does not name a tracked file")]

      Date.compare(entry.due, today) == :lt ->
        [violation(path, "clause exception #{entry.identifier} expired on #{entry.due}")]

      Date.compare(entry.due, Date.add(today, 30)) == :gt ->
        [violation(path, "clause exception #{entry.identifier} is due more than 30 days out")]

      entry.lines <= @max_clause_lines ->
        [violation(path, "clause exception #{entry.identifier} is not over #{@max_clause_lines} lines")]

      not section_index?(Path.join(root, path)) ->
        [violation(path, "clause exception #{entry.identifier} lacks a nearby locality split index")]

      true ->
        []
    end
  end

  defp handwritten_violations(absolute_path, path, settings, today) do
    contents = File.read!(absolute_path)
    line_count = physical_line_count(contents)
    file_violations = if line_count > @max_file_lines, do: [violation(path, "#{line_count} lines exceeds #{@max_file_lines}")], else: []

    if Path.extname(path) in [".ex", ".exs"] do
      file_violations ++ ast_violations(contents, path, settings.clause_exceptions, today)
    else
      file_violations
    end
  end

  defp ast_violations(contents, path, exceptions, today) do
    case Code.string_to_quoted(contents, columns: true, token_metadata: true, file: path) do
      {:ok, ast} ->
        {_, violations} =
          Macro.prewalk(ast, [], fn
            {kind, metadata, arguments} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
              clause = clause_violation(node, metadata, arguments, path, exceptions, today)
              nesting = nesting_violation(arguments, metadata, path)
              {node, nesting ++ clause ++ acc}

            node, acc ->
              remote = remote_call_violation(node, path)
              {node, remote ++ acc}
          end)

        violations

      {:error, {_metadata, message, token}} ->
        [violation(path, "cannot parse Elixir AST: #{message} #{inspect(token)}")]
    end
  end

  defp clause_violation(_node, metadata, arguments, path, exceptions, today) do
    start_line = Keyword.fetch!(metadata, :line)
    end_line = metadata |> Keyword.get(:end, Keyword.get(metadata, :end_of_expression, [])) |> Keyword.get(:line, start_line)
    lines = end_line - start_line + 1
    identifier = clause_identifier(arguments, start_line)

    if lines > @max_clause_lines and not current_exception?(exceptions, path, identifier, lines, today) do
      [violation(path, "#{identifier} spans #{lines} lines; maximum is #{@max_clause_lines}")]
    else
      []
    end
  end

  defp clause_identifier([head | _], line) do
    {call, _guard} =
      case head do
        {:when, _, [call | guard]} -> {call, guard}
        call -> {call, []}
      end

    case call do
      {name, _, arguments} when is_atom(name) and is_list(arguments) -> "#{name}/#{length(arguments)}@#{line}"
      {name, _, nil} when is_atom(name) -> "#{name}/0@#{line}"
      _ -> "clause@#{line}"
    end
  end

  defp current_exception?(exceptions, path, identifier, lines, today) do
    Enum.any?(exceptions, fn entry ->
      case entry do
        %{path: ^path, identifier: ^identifier, lines: ^lines, due: %Date{} = due} ->
          Date.compare(due, today) != :lt

        _other ->
          false
      end
    end)
  end

  defp nesting_violation(arguments, metadata, path) do
    depth = max_nesting(arguments, 0)

    if depth > @max_nesting_depth do
      [violation(path, "function body nesting depth #{depth} at line #{metadata[:line]}; maximum is #{@max_nesting_depth}")]
    else
      []
    end
  end

  defp max_nesting({:quote, _, _arguments}, depth), do: depth

  defp max_nesting({form, _, arguments}, depth)
       when form in @nesting_forms and is_list(arguments) do
    nested_depth = depth + 1
    Enum.max([nested_depth | Enum.map(arguments, &max_nesting(&1, nested_depth))])
  end

  defp max_nesting({_form, _, arguments}, depth) when is_list(arguments),
    do: Enum.max([depth | Enum.map(arguments, &max_nesting(&1, depth))])

  defp max_nesting(list, depth) when is_list(list),
    do: Enum.max([depth | Enum.map(list, &max_nesting(&1, depth))])

  defp max_nesting(tuple, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> max_nesting(depth)

  defp max_nesting(_other, depth), do: depth

  defp remote_call_violation({{:., metadata, [_receiver, name]}, call_metadata, arguments} = node, path)
       when is_atom(name) and is_list(arguments) do
    depth = remote_call_depth(node)

    if remote_call?(call_metadata, arguments) and depth > @max_remote_call_depth do
      line = Keyword.get(call_metadata, :line, Keyword.get(metadata, :line, 1))
      [violation(path, "nested remote-call depth #{depth} at line #{line}; maximum is #{@max_remote_call_depth}")]
    else
      []
    end
  end

  defp remote_call_violation(_node, _path), do: []

  defp remote_call_depth({{:., _, [receiver, name]}, call_metadata, arguments})
       when is_atom(name) and is_list(arguments) do
    increment = if remote_call?(call_metadata, arguments), do: 1, else: 0
    increment + remote_call_depth(receiver)
  end

  defp remote_call_depth({:|>, _, _arguments}), do: 0
  defp remote_call_depth(_other), do: 0

  defp remote_call?(metadata, arguments),
    do: arguments != [] or Keyword.has_key?(metadata, :closing)

  defp generated_header_violations(absolute_path, path, generated) do
    source = generated |> Enum.find(&(&1.path == path)) |> Map.fetch!(:source)

    header =
      absolute_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.take(5)
      |> Enum.join("\n")

    []
    |> maybe_add(not String.contains?(header, "Generated from: #{source}"), path, "first five non-empty lines must declare Generated from: #{source}")
    |> maybe_add(not String.contains?(header, "DO NOT EDIT"), path, "first five non-empty lines must declare DO NOT EDIT")
  end

  defp maybe_add(violations, true, path, message), do: [violation(path, message) | violations]
  defp maybe_add(violations, false, _path, _message), do: violations

  defp code_path?(path, settings) do
    Path.extname(path) in settings.code_extensions or Path.basename(path) in settings.code_basenames
  end

  defp physical_line_count(""), do: 0

  defp physical_line_count(contents) do
    lines = contents |> String.split("\n") |> length()
    if String.ends_with?(contents, "\n"), do: lines - 1, else: lines
  end

  defp section_index?(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.take(12)
    |> Enum.any?(&String.contains?(&1, "Locality split index:"))
  end

  defp violation(path, message), do: %{path: path, message: message}
end
