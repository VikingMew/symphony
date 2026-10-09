defmodule SymphonyElixir.Locality do
  @moduledoc false

  @max_file_lines 1_000
  @max_clause_lines 60
  @max_nesting_depth 2
  @max_remote_call_depth 2
  @nesting_forms [:if, :unless, :case, :cond, :fn, :for, :with]
  @required_exception_fields ~w(path identifier lines split owner)a

  @type config :: %{
          required(:code_extensions) => [String.t()],
          required(:code_basenames) => [String.t()],
          required(:data_paths) => [String.t()],
          required(:generated) => [map()],
          required(:clause_exceptions) => [map()]
        }
  @type locality_violation :: %{required(:path) => String.t(), required(:message) => String.t()}
  @type waterline :: %{
          required(:exemptions_remaining) => non_neg_integer(),
          required(:max_file_lines) => non_neg_integer(),
          required(:max_clause_lines) => non_neg_integer()
        }
  @type locality_result :: %{required(:violations) => [locality_violation()], required(:waterline) => waterline()}

  @spec locality_config(Path.t()) :: config()
  def locality_config(root \\ File.cwd!()) do
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

  @spec check_locality(Path.t()) :: locality_result()
  def check_locality(root \\ File.cwd!()) do
    paths = tracked_paths(root)
    settings = locality_config(root)

    check_paths(root, paths, settings)
  end

  @spec check_paths(Path.t(), [String.t()], config()) :: locality_result()
  def check_paths(root, paths, settings) do
    generated_paths = MapSet.new(settings.generated, &Map.get(&1, :path))
    data_paths = MapSet.new(settings.data_paths)

    measurements =
      paths
      |> Enum.filter(&code_path?(&1, settings))
      |> Enum.reject(&MapSet.member?(data_paths, &1))
      |> Enum.map(&measure_code_path(root, &1, settings, generated_paths))

    violations =
      (manifest_violations(root, paths, settings, measured_clause_keys(measurements)) ++
         Enum.flat_map(measurements, & &1.violations))
      |> Enum.sort_by(&{&1.path, &1.message})

    %{
      violations: violations,
      waterline: %{
        exemptions_remaining: length(settings.clause_exceptions),
        max_file_lines: measurements |> Enum.map(& &1.file_lines) |> Enum.max(fn -> 0 end),
        max_clause_lines: measurements |> Enum.map(& &1.clause_lines) |> Enum.max(fn -> 0 end)
      }
    }
  end

  defp measured_clause_keys(measurements) do
    Enum.reduce(measurements, MapSet.new(), &MapSet.union(&1.clauses, &2))
  end

  @spec format_report(locality_result()) :: String.t()
  def format_report(%{violations: violations, waterline: waterline}) do
    summary =
      "locality_waterline exemptions_remaining=#{waterline.exemptions_remaining} " <>
        "max_file_lines=#{waterline.max_file_lines} max_clause_lines=#{waterline.max_clause_lines}"

    case violations do
      [] -> "#{summary}\nLocality check passed.\n"
      _ -> "#{summary}\n#{format_violations(violations)}"
    end
  end

  defp format_violations(violations) do
    details = Enum.map_join(violations, "\n", &"#{&1.path}: #{&1.message}")
    "Locality check failed with #{length(violations)} violation(s):\n#{details}\n"
  end

  defp manifest_violations(root, paths, settings, clause_keys) do
    tracked = MapSet.new(paths)

    stale_data =
      settings.data_paths
      |> Enum.reject(&MapSet.member?(tracked, &1))
      |> Enum.map(&new_violation(&1, "data exclusion does not name a tracked file"))

    generated =
      Enum.flat_map(settings.generated, fn entry ->
        cond do
          Map.keys(entry) |> Enum.sort() != [:path, :source] ->
            [new_violation(Map.get(entry, :path, "config/locality.exs"), "generated entry requires exactly path and source")]

          not MapSet.member?(tracked, entry.path) ->
            [new_violation(entry.path, "generated exclusion does not name a tracked file")]

          true ->
            []
        end
      end)

    exceptions =
      Enum.flat_map(
        settings.clause_exceptions,
        &exception_violations(&1, tracked, root, clause_keys)
      )

    stale_data ++ generated ++ exceptions
  end

  defp exception_violations(entry, tracked, root, clause_keys) do
    missing = Enum.reject(@required_exception_fields, &Map.has_key?(entry, &1))
    path = Map.get(entry, :path, "config/locality.exs")

    cond do
      missing != [] ->
        [new_violation(path, "clause exception missing fields: #{Enum.join(missing, ", ")}")]

      not MapSet.member?(tracked, path) ->
        [new_violation(path, "clause exception does not name a tracked file")]

      entry.lines <= @max_clause_lines ->
        [new_violation(path, "clause exception #{entry.identifier} is not over #{@max_clause_lines} lines")]

      not MapSet.member?(clause_keys, {path, entry.identifier, entry.lines}) ->
        [new_violation(path, "clause exception #{entry.identifier} does not match a current overlong clause")]

      not section_index?(Path.join(root, path)) ->
        [new_violation(path, "clause exception #{entry.identifier} lacks a nearby locality split index")]

      true ->
        []
    end
  end

  defp measure_code_path(root, path, settings, generated_paths) do
    absolute_path = Path.join(root, path)
    contents = File.read!(absolute_path)
    file_lines = physical_line_count(contents)

    if MapSet.member?(generated_paths, path) do
      %{
        violations: generated_header_violations(absolute_path, path, settings.generated),
        file_lines: file_lines,
        clause_lines: 0,
        clauses: MapSet.new()
      }
    else
      measure_handwritten(contents, path, settings, file_lines)
    end
  end

  defp measure_handwritten(contents, path, settings, line_count) do
    file_violations = if line_count > @max_file_lines, do: [new_violation(path, "#{line_count} lines exceeds #{@max_file_lines}")], else: []

    if Path.extname(path) in [".ex", ".exs"] do
      {ast_violations, max_clause_lines, clauses} = measure_ast(contents, path, settings.clause_exceptions)

      %{
        violations: file_violations ++ ast_violations,
        file_lines: line_count,
        clause_lines: max_clause_lines,
        clauses: clauses
      }
    else
      %{violations: file_violations, file_lines: line_count, clause_lines: 0, clauses: MapSet.new()}
    end
  end

  defp measure_ast(contents, path, exceptions) do
    case Code.string_to_quoted(contents, columns: true, token_metadata: true, file: path) do
      {:ok, ast} ->
        {_, {violations, max_clause_lines, clauses}} =
          Macro.prewalk(ast, {[], 0, MapSet.new()}, fn
            {kind, metadata, arguments} = node, {acc, maximum, clauses}
            when kind in [:def, :defp, :defmacro, :defmacrop] ->
              {clause, identifier, lines} = clause_violation(metadata, arguments, path, exceptions)
              nesting = nesting_violation(arguments, metadata, path)
              clause_key = {path, identifier, lines}
              {node, {nesting ++ clause ++ acc, max(maximum, lines), MapSet.put(clauses, clause_key)}}

            node, {acc, maximum, clauses} ->
              remote = remote_call_violation(node, path)
              {node, {remote ++ acc, maximum, clauses}}
          end)

        {violations, max_clause_lines, clauses}

      {:error, {_metadata, message, token}} ->
        {[new_violation(path, "cannot parse Elixir AST: #{message} #{inspect(token)}")], 0, MapSet.new()}
    end
  end

  defp clause_violation(metadata, arguments, path, exceptions) do
    start_line = Keyword.fetch!(metadata, :line)
    end_line = metadata |> Keyword.get(:end, Keyword.get(metadata, :end_of_expression, [])) |> Keyword.get(:line, start_line)
    lines = end_line - start_line + 1
    identifier = clause_identifier(arguments, start_line)

    violations =
      if lines > @max_clause_lines and not current_exception?(exceptions, path, identifier, lines) do
        [new_violation(path, "#{identifier} spans #{lines} lines; maximum is #{@max_clause_lines}")]
      else
        []
      end

    {violations, identifier, lines}
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

  defp current_exception?(exceptions, path, identifier, lines) do
    Enum.any?(exceptions, fn entry ->
      case entry do
        %{path: ^path, identifier: ^identifier, lines: ^lines} ->
          true

        _other ->
          false
      end
    end)
  end

  defp nesting_violation(arguments, metadata, path) do
    depth = max_nesting(arguments, 0)

    if depth > @max_nesting_depth do
      [new_violation(path, "function body nesting depth #{depth} at line #{metadata[:line]}; maximum is #{@max_nesting_depth}")]
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
      [new_violation(path, "nested remote-call depth #{depth} at line #{line}; maximum is #{@max_remote_call_depth}")]
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
    |> maybe_prepend_violation(
      not String.contains?(header, "Generated from: #{source}"),
      path,
      "first five non-empty lines must declare Generated from: #{source}"
    )
    |> maybe_prepend_violation(
      not String.contains?(header, "DO NOT EDIT"),
      path,
      "first five non-empty lines must declare DO NOT EDIT"
    )
  end

  defp maybe_prepend_violation(violations, true, path, message),
    do: [new_violation(path, message) | violations]

  defp maybe_prepend_violation(violations, false, _path, _message), do: violations

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

  defp new_violation(path, message), do: %{path: path, message: message}
end
