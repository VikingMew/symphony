defmodule SymphonyElixir.AgentCodeNCheck do
  @moduledoc """
  Checks deterministic Agent-facing code navigation rules and their shrinking baseline.
  """

  @baseline_path "config/agent_code_navigation_baseline.yml"
  @source_patterns ["lib/**/*.ex", "test/**/*.ex", "test/**/*.exs"]
  @directory_roots ~w(.github config docs lib scripts test)
  @directory_pattern ~r/(?:^\d{4}(?:-?\d{2}){2}$|^(?:phase|stage|batch)[_-]?\d+$)/i

  @type report :: %{required(String.t()) => term()}
  @type declaration :: %{
          required(:category) => String.t(),
          required(:line) => pos_integer(),
          required(:module) => String.t() | nil,
          required(:name) => String.t(),
          required(:path) => String.t()
        }

  @spec check(keyword()) :: report()
  def check(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    baseline_path = Keyword.get(opts, :baseline, @baseline_path)
    {declarations, top_level_modules, source_errors} = scan_sources(root)

    findings =
      declarations
      |> navigation_findings(top_level_modules, root)
      |> Enum.sort()

    {baseline_remaining, baseline_errors} =
      validate_baseline(root, baseline_path, findings, Keyword.get(opts, :base_baseline, :from_git))

    errors = Enum.sort(source_errors ++ baseline_errors)

    %{
      "schema" => "agent-facing-code-navigation-report",
      "status" => if(errors == [], do: "pass", else: "fail"),
      "navigation_baseline_remaining" => baseline_remaining,
      "findings" => findings,
      "errors" => errors
    }
  end

  @spec exit_code(report()) :: 0 | 1
  def exit_code(%{"status" => "pass"}), do: 0
  def exit_code(%{"status" => "fail"}), do: 1

  @spec human_output(report()) :: String.t()
  def human_output(report) do
    "agent_code_n.check: #{String.upcase(report["status"])} navigation baseline remaining: #{report["navigation_baseline_remaining"]}"
  end

  defp scan_sources(root) do
    source_paths =
      @source_patterns
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1), match_dot: true))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(source_paths, {[], %{}, []}, fn path, {declarations, modules_by_path, errors} ->
      case root |> Path.join(path) |> File.read!() |> Code.string_to_quoted(columns: true, token_metadata: true) do
        {:ok, ast} ->
          {path_declarations, top_level_modules} = walk(ast, path, nil, [], [])

          {
            path_declarations ++ declarations,
            Map.put(modules_by_path, path, Enum.reverse(top_level_modules)),
            errors
          }

        {:error, reason} ->
          {declarations, Map.put(modules_by_path, path, []), ["source.parse: #{path}: #{inspect(reason)}" | errors]}
      end
    end)
    |> then(fn {declarations, modules_by_path, errors} ->
      {Enum.reverse(declarations), modules_by_path, Enum.reverse(errors)}
    end)
  end

  defp walk({:defmodule, meta, [alias_ast, body]}, path, parent_module, declarations, top_level_modules) do
    module = module_name(alias_ast, parent_module)
    line = Keyword.fetch!(meta, :line)
    declaration = declaration("module", module_tail(module), path, line, module)
    top_level_modules = if parent_module == nil, do: [{module, line} | top_level_modules], else: top_level_modules
    walk(keyword_body(body), path, module, [declaration | declarations], top_level_modules)
  end

  defp walk({kind, meta, [head, body]}, path, module, declarations, top_level_modules)
       when kind in [:def, :defp] do
    {name, arity} = function_identity(head)
    category = if test_helper_module?(module), do: "fixture", else: "function"
    declaration = declaration(category, Atom.to_string(name), path, Keyword.fetch!(meta, :line), module, arity)
    walk(keyword_body(body), path, module, [declaration | declarations], top_level_modules)
  end

  defp walk({:@, meta, [{kind, _, [type_ast]}]}, path, module, declarations, top_level_modules)
       when kind in [:type, :opaque] do
    {name, arity} = type_identity(type_ast)
    declaration = declaration("type", Atom.to_string(name), path, Keyword.fetch!(meta, :line), module, arity)
    {declarations, top_level_modules} = {[declaration | declarations], top_level_modules}
    walk(type_ast, path, module, declarations, top_level_modules)
  end

  defp walk({_, _, args}, path, module, declarations, top_level_modules) when is_list(args) do
    walk(args, path, module, declarations, top_level_modules)
  end

  defp walk(list, path, module, declarations, top_level_modules) when is_list(list) do
    Enum.reduce(list, {declarations, top_level_modules}, fn node, {declarations, top_level_modules} ->
      walk(node, path, module, declarations, top_level_modules)
    end)
  end

  defp walk(_node, _path, _module, declarations, top_level_modules), do: {declarations, top_level_modules}

  defp keyword_body(body) when is_list(body), do: Keyword.get(body, :do)
  defp keyword_body(_body), do: nil

  defp module_name({:__aliases__, _, parts}, parent_module) do
    name = Enum.map_join(parts, ".", &Atom.to_string/1)

    if parent_module && hd(parts) not in [:SymphonyElixir, :SymphonyElixirWeb, :Mix] do
      parent_module <> "." <> name
    else
      name
    end
  end

  defp module_tail(module), do: module |> String.split(".") |> List.last()

  defp function_identity({:when, _, [head | _guards]}), do: function_identity(head)
  defp function_identity({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp type_identity({:"::", _, [head, _definition]}), do: function_identity(head)
  defp type_identity(head), do: function_identity(head)

  defp declaration(category, name, path, line, module, arity \\ nil) do
    %{
      category: category,
      name: name,
      path: path,
      line: line,
      module: module,
      symbol: {module, name, arity}
    }
  end

  defp navigation_findings(declarations, top_level_modules, root) do
    logical_declarations = logical_declarations(declarations)

    duplicate_findings(logical_declarations) ++
      near_name_findings(logical_declarations) ++
      file_module_findings(top_level_modules) ++
      directory_findings(root) ++
      resident_rule_findings(root) ++
      test_boundary_findings(logical_declarations, top_level_modules) ++
      navigation_entry_findings(root)
  end

  defp logical_declarations(declarations) do
    declarations
    |> Enum.group_by(fn declaration ->
      if declaration.category in ["function", "fixture"] do
        {declaration.category, declaration.symbol}
      else
        {declaration.category, declaration.path, declaration.line}
      end
    end)
    |> Enum.map(fn {_identity, rows} ->
      first = Enum.min_by(rows, &{&1.path, &1.line})
      Map.put(first, :locations, rows |> Enum.map(&location/1) |> Enum.uniq() |> Enum.sort())
    end)
  end

  defp duplicate_findings(declarations) do
    declarations
    |> Enum.group_by(&{&1.category, String.downcase(&1.name)})
    |> Enum.flat_map(fn {{category, normalized}, rows} ->
      if length(rows) > 1 do
        [finding("N-01", category, normalized, locations(rows))]
      else
        []
      end
    end)
  end

  defp near_name_findings(declarations) do
    declarations
    |> Enum.group_by(&{&1.category, normalize_name(&1.name)})
    |> Enum.flat_map(fn {{category, normalized}, rows} -> near_name_finding(category, normalized, rows) end)
  end

  defp near_name_finding(category, normalized, rows) do
    if rows |> Enum.map(& &1.name) |> Enum.uniq() |> length() > 1 do
      detail =
        rows
        |> Enum.group_by(& &1.name)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(";", fn {name, named_rows} -> "#{name}@#{locations(named_rows)}" end)

      ["N-03|#{category}|#{normalized}|#{detail}"]
    else
      []
    end
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.replace("_", "")
    |> singularize()
  end

  defp singularize(name) do
    cond do
      Regex.match?(~r/[^aeiou]ies$/, name) -> String.replace_suffix(name, "ies", "y")
      Regex.match?(~r/(?:ches|shes|xes|zes)$/, name) -> String.slice(name, 0, byte_size(name) - 2)
      String.ends_with?(name, "s") and not String.ends_with?(name, "ss") -> String.trim_trailing(name, "s")
      true -> name
    end
  end

  defp file_module_findings(modules_by_path) do
    Enum.flat_map(modules_by_path, fn {path, modules} -> file_module_finding(path, modules) end)
  end

  defp file_module_finding(path, []), do: ["N-05|missing-top-level-module|#{path}"]

  defp file_module_finding(path, modules) when length(modules) > 1 do
    module_list = Enum.map_join(modules, ",", fn {module, line} -> "#{module}@#{line}" end)
    ["N-05|multiple-top-level-modules|#{path}|#{module_list}"]
  end

  defp file_module_finding(path, [{module, line}]) do
    expected = expected_module_suffix(path)

    if module == expected or String.ends_with?(module, "." <> expected) do
      []
    else
      ["N-05|file-module-mismatch|#{path}|expected:#{expected}|actual:#{module}@#{line}"]
    end
  end

  defp expected_module_suffix(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.split(".")
    |> Enum.map_join(".", &Macro.camelize/1)
  end

  defp directory_findings(root) do
    Enum.flat_map(@directory_roots, fn directory_root ->
      root
      |> Path.join(directory_root)
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.filter(fn path -> path |> Path.split() |> Enum.any?(&Regex.match?(@directory_pattern, &1)) end)
      |> Enum.map(&"N-06|forbidden-directory|#{&1}")
    end)
  end

  defp resident_rule_findings(root) do
    content = read_or_empty(Path.join(root, "AGENTS.md"))

    for {label, command} <- [Build: "mix build", Run: "mix symphony.migrate", Test: "scripts/check.sh"],
        not command_in_section?(content, label, command) do
      "N-07|missing-command|#{label}|#{command}"
    end
  end

  defp command_in_section?(content, label, command) do
    case Regex.run(Regex.compile!("(?ms)^### #{label}\\s*$\\n(.*?)(?=^### |\\z)"), content) do
      [_, section] -> String.contains?(section, "`#{command}`")
      nil -> false
    end
  end

  defp test_boundary_findings(declarations, modules_by_path) do
    module_findings =
      Enum.flat_map(modules_by_path, fn
        {"test/support/" <> _path = path, modules} ->
          for {module, line} <- modules, not test_helper_module?(module) do
            "N-08|support-module-namespace|#{path}:#{line}|#{module}"
          end

        {"test/" <> _path = path, modules} ->
          for {module, line} <- modules, not String.ends_with?(module, "Test") do
            "N-08|test-module-suffix|#{path}:#{line}|#{module}"
          end

        _other ->
          []
      end)

    collision_findings =
      declarations
      |> Enum.group_by(&String.downcase(&1.name))
      |> Enum.flat_map(fn {normalized, rows} ->
        helpers = Enum.filter(rows, &(&1.category in ["fixture", "module"] and test_helper_module?(&1.module)))
        products = Enum.reject(rows, &(&1.category == "fixture" or test_path?(&1.path)))

        if helpers != [] and products != [] do
          ["N-08|helper-product-collision|#{normalized}|helper:#{locations(helpers)}|product:#{locations(products)}"]
        else
          []
        end
      end)

    module_findings ++ collision_findings
  end

  defp navigation_entry_findings(root) do
    content = read_or_empty(Path.join(root, "AGENTS.md"))

    []
    |> maybe_add(not String.contains?(content, "[module map](docs/design.md)"), "N-09|missing-module-map|AGENTS.md")
    |> maybe_add(not Regex.match?(~r/`rg [^`]+`/, content), "N-09|missing-rg-command|AGENTS.md")
  end

  defp validate_baseline(root, relative_path, findings, base_baseline_option) do
    current = read_baseline(Path.join(root, relative_path))
    base = base_baseline(root, relative_path, base_baseline_option)

    baseline_remaining =
      case current do
        {:ok, rows} -> length(rows)
        _other -> 0
      end

    errors =
      baseline_shape_errors(current) ++
        baseline_match_errors(current, findings) ++
        baseline_ratchet_errors(current, base, findings)

    {baseline_remaining, errors}
  end

  defp read_baseline(path) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          {:ok, _value} -> {:error, "baseline.schema: expected a YAML list of finding identities"}
          {:error, reason} -> {:error, "baseline.schema: invalid YAML: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, "baseline.file: cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp baseline_shape_errors(:missing), do: []
  defp baseline_shape_errors({:error, error}), do: [error]

  defp baseline_shape_errors({:ok, rows}) do
    cond do
      rows == [] ->
        ["baseline.schema: empty baseline must be deleted"]

      not Enum.all?(rows, &(is_binary(&1) and String.trim(&1) == &1 and &1 != "")) ->
        ["baseline.schema: every entry must be one non-empty exact finding identity"]

      rows != Enum.sort(Enum.uniq(rows)) ->
        ["baseline.schema: entries must be unique and sorted"]

      true ->
        []
    end
  end

  defp baseline_match_errors({:ok, rows}, findings) do
    (findings -- rows)
    |> Enum.map(&"baseline.unregistered: #{&1}")
    |> Kernel.++(Enum.map(rows -- findings, &"baseline.stale: #{&1}"))
  end

  defp baseline_match_errors(:missing, []), do: []
  defp baseline_match_errors(:missing, findings), do: Enum.map(findings, &"baseline.unregistered: #{&1}")
  defp baseline_match_errors({:error, _error}, _findings), do: []

  defp baseline_ratchet_errors({:ok, rows}, :missing, findings) do
    if rows == findings, do: [], else: ["baseline.initialization: baseline must equal the current exact finding set"]
  end

  defp baseline_ratchet_errors({:ok, rows}, {:ok, base_rows}, _findings) do
    Enum.map(rows -- base_rows, &"baseline.added: #{&1}")
  end

  defp baseline_ratchet_errors(:missing, {:ok, _base_rows}, []), do: []
  defp baseline_ratchet_errors(:missing, :missing, []), do: []
  defp baseline_ratchet_errors(_current, {:error, error}, _findings), do: [error]
  defp baseline_ratchet_errors(_current, _base, _findings), do: []

  defp base_baseline(_root, _path, option) when option == :missing, do: :missing
  defp base_baseline(_root, _path, rows) when is_list(rows), do: {:ok, rows}

  defp base_baseline(root, path, :from_git) do
    case System.cmd("git", ["merge-base", "HEAD", "origin/main"], cd: root, stderr_to_stdout: true) do
      {merge_base, 0} -> read_base_baseline(root, path, String.trim(merge_base))
      {output, status} -> {:error, "baseline.merge_base: git exited #{status}: #{String.trim(output)}"}
    end
  end

  defp read_base_baseline(root, path, merge_base) do
    case System.cmd("git", ["ls-tree", "--name-only", merge_base, "--", path], cd: root, stderr_to_stdout: true) do
      {"", 0} ->
        :missing

      {_listed_path, 0} ->
        parse_base_baseline(root, path, merge_base)

      {output, status} ->
        {:error, "baseline.merge_base: git ls-tree exited #{status}: #{String.trim(output)}"}
    end
  end

  defp parse_base_baseline(root, path, merge_base) do
    case System.cmd("git", ["show", "#{merge_base}:#{path}"], cd: root, stderr_to_stdout: true) do
      {content, 0} ->
        case YamlElixir.read_from_string(content) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          {:ok, _value} -> {:error, "baseline.base_schema: expected a YAML list of finding identities"}
          {:error, reason} -> {:error, "baseline.base_schema: invalid YAML: #{inspect(reason)}"}
        end

      {output, status} ->
        {:error, "baseline.merge_base: git show exited #{status}: #{String.trim(output)}"}
    end
  end

  defp finding(rule, category, name, location_text), do: "#{rule}|#{category}|#{name}|#{location_text}"
  defp locations(rows), do: rows |> Enum.flat_map(& &1.locations) |> Enum.uniq() |> Enum.sort() |> Enum.join(",")
  defp location(row), do: "#{row.path}:#{row.line}"
  defp test_path?("test/" <> _path), do: true
  defp test_path?(_path), do: false

  defp test_helper_module?(module) when is_binary(module) do
    String.starts_with?(module, "SymphonyElixir.TestSupport") or "Fixtures" in String.split(module, ".")
  end

  defp test_helper_module?(_module), do: false

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp maybe_add(items, true, item), do: [item | items]
  defp maybe_add(items, false, _item), do: items
end
