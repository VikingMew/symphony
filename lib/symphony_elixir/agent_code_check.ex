defmodule SymphonyElixir.AgentCodeCheck do
  @moduledoc """
  Evaluates the G-group governance registry owned by
  `docs/agent-facing-code-design.md`.
  """

  @registry_path "config/agent_code_governance.yml"
  @threshold_ids ~w(file_lines function_lines nesting_depth identifier_occurrences full_gate_minutes change_lines)
  @clause_ids Enum.map(1..8, &"G-0#{&1}")
  @evidence_tiers ~w(machine human orientation)
  @exclusion_categories ~w(generated third_party binary data)
  @registry_keys ~w(schema owner specification scope clauses gates thresholds)
  @specification_keys ~w(version effective_on changes)
  @change_keys ~w(version effective_on gate summary)
  @scope_keys ~w(handwritten excluded)
  @handwritten_keys ~w(path)
  @excluded_keys ~w(path category reason)
  @clause_keys ~w(id evidence_tier evidence_method)
  @gate_keys ~w(id checker implementation fast_chain thresholds)
  @threshold_keys ~w(id kind scope unit redline default source_nature evidence_tier status default_exceedance_reason calibration)
  @threshold_scope_keys ~w(paths language)
  @calibration_keys ~w(method sample sample_value date distribution)
  @distribution_keys ~w(population points)
  @distribution_point_keys ~w(statistic value)
  @nested_forms [:case, :cond, :for, :fn, :if, :receive, :try, :unless, :with]

  @type finding :: %{required(String.t()) => term()}
  @type report :: %{required(String.t()) => term()}
  @type source_report :: %{required(String.t()) => term()}
  @type scope_result :: %{
          required(:tracked) => [String.t()],
          required(:included) => [String.t()],
          required(:excluded) => [map()]
        }

  @spec check(keyword()) :: report()
  def check(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    registry_path = Keyword.get(opts, :registry, @registry_path)
    registry = load_registry!(Path.join(root, registry_path), root)
    scope = resolve_scope!(root, registry["scope"])
    measurements = Enum.flat_map(registry["thresholds"], &measure_threshold(root, scope, &1))
    {findings, errors} = classify_threshold_measurements(measurements)
    findings = Enum.sort_by(findings, &{&1["threshold"], &1["target"], &1["tier"]})
    errors = Enum.sort(errors)
    failures = Enum.count(findings, &(&1["status"] == "failure")) + length(errors)
    waterline = waterline(registry, measurements)

    %{
      "schema" => "agent-facing-code-report",
      "status" => if(failures == 0, do: "pass", else: "fail"),
      "governance" => governance_summary(registry),
      "scope" => scope_summary(root, scope),
      "waterline" => waterline,
      "summary" => report_summary(registry, findings, errors, waterline),
      "findings" => findings,
      "errors" => errors
    }
  end

  @spec source_list(keyword()) :: source_report()
  def source_list(opts \\ []) do
    {root, scope} = load_scope!(opts)

    %{
      "schema" => "agent-facing-code-source-list",
      "paths" => scope.included,
      "summary" => scope_summary(root, scope)
    }
  end

  @spec source_stats(keyword()) :: source_report()
  def source_stats(opts \\ []) do
    {root, scope} = load_scope!(opts)
    %{"schema" => "agent-facing-code-source-stats", "summary" => scope_summary(root, scope)}
  end

  @spec exit_code(report()) :: 0 | 1
  def exit_code(%{"status" => "pass"}), do: 0
  def exit_code(%{"status" => "fail"}), do: 1

  @spec human_output(report()) :: String.t()
  def human_output(report) do
    summary = report["summary"]
    waterline = report["waterline"]

    header =
      "agent_code.check: #{String.upcase(report["status"])} " <>
        "(#{summary["thresholds"]} thresholds, #{summary["active_thresholds"]} active, " <>
        "#{summary["failures"]} failures, #{summary["default_notices"]} default notices)"

    waterline_line =
      "agent_code waterline: baseline_remaining=#{waterline["baseline_remaining"]} " <>
        "file_lines_headroom=#{waterline["file_lines_headroom"]}"

    details =
      report["errors"] ++
        (report["findings"]
         |> Enum.filter(&(&1["status"] == "failure"))
         |> Enum.map(fn finding ->
           "#{finding["threshold"]}:#{finding["target"]} " <>
             "value=#{finding["value"]} limit=#{finding["limit"]}"
         end))

    Enum.join([header, waterline_line | details], "\n")
  end

  defp load_scope!(opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    registry_path = Keyword.get(opts, :registry, @registry_path)
    registry = load_registry!(Path.join(root, registry_path), root)
    {root, resolve_scope!(root, registry["scope"])}
  end

  defp load_registry!(path, root) do
    registry = yaml_map!(path)
    exact_keys!(registry, @registry_keys, "registry")

    unless registry["schema"] == "agent-facing-code-governance" and
             nonempty_string?(registry["owner"]) do
      raise ArgumentError, "invalid agent-facing code governance header"
    end

    scope = validate_scope!(registry["scope"])
    clauses = validate_clauses!(registry["clauses"])
    thresholds = validate_thresholds!(registry["thresholds"])
    gates = validate_gates!(registry["gates"], thresholds, root)
    specification = validate_specification!(registry["specification"], gates)

    registry
    |> Map.put("scope", scope)
    |> Map.put("clauses", clauses)
    |> Map.put("thresholds", thresholds)
    |> Map.put("gates", gates)
    |> Map.put("specification", specification)
  end

  defp validate_scope!(scope) do
    exact_keys!(scope, @scope_keys, "repository scope")

    handwritten =
      validate_entries!(scope["handwritten"], @handwritten_keys, "handwritten scope", fn entry ->
        nonempty_string?(entry["path"])
      end)

    excluded =
      validate_entries!(scope["excluded"], @excluded_keys, "excluded scope", fn entry ->
        nonempty_string?(entry["path"]) and entry["category"] in @exclusion_categories and
          nonempty_string?(entry["reason"])
      end)

    identities = Enum.map(handwritten, & &1["path"]) ++ Enum.map(excluded, & &1["path"])
    ensure_unique!(identities, "scope path patterns")
    %{"handwritten" => handwritten, "excluded" => excluded}
  end

  defp validate_clauses!(clauses) when is_list(clauses) do
    clauses =
      Enum.map(clauses, fn clause ->
        exact_keys!(clause, @clause_keys, "G clause")

        unless clause["id"] in @clause_ids and clause["evidence_tier"] in @evidence_tiers and
                 nonempty_string?(clause["evidence_method"]) do
          raise ArgumentError, "invalid G clause #{inspect(clause["id"])}"
        end

        clause
      end)

    ids = Enum.map(clauses, & &1["id"])

    if Enum.sort(ids) != @clause_ids or length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "registry must contain G-01 through G-08 exactly once"
    end

    clauses
  end

  defp validate_clauses!(value), do: raise(ArgumentError, "clauses must be a list: #{inspect(value)}")

  defp validate_thresholds!(thresholds) when is_list(thresholds) do
    thresholds = Enum.map(thresholds, &validate_threshold!/1)
    ids = Enum.map(thresholds, & &1["id"])

    if Enum.sort(ids) != Enum.sort(@threshold_ids) or length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "registry must contain each of the six thresholds exactly once"
    end

    thresholds
  end

  defp validate_thresholds!(value),
    do: raise(ArgumentError, "thresholds must be a list: #{inspect(value)}")

  defp validate_threshold!(threshold) when is_map(threshold) do
    exact_keys!(threshold, @threshold_keys, "threshold")
    exact_keys!(threshold["scope"], @threshold_scope_keys, "threshold scope")

    unless valid_threshold?(threshold),
      do: raise(ArgumentError, "invalid threshold #{inspect(threshold["id"])}")

    validate_calibration!(threshold["calibration"], threshold["id"])
    threshold
  end

  defp validate_threshold!(value),
    do: raise(ArgumentError, "threshold must be a map: #{inspect(value)}")

  defp valid_threshold?(threshold) do
    Enum.all?([
      valid_threshold_identity?(threshold),
      valid_threshold_text?(threshold),
      valid_threshold_scope?(threshold),
      threshold?(threshold["redline"]),
      threshold?(threshold["default"])
    ])
  end

  defp valid_threshold_identity?(threshold) do
    threshold["id"] in @threshold_ids and
      threshold["kind"] in ~w(file_lines function_lines nesting_depth identifier_occurrences recorded_sample) and
      threshold["evidence_tier"] in @evidence_tiers and
      threshold["status"] in ~w(enforced record_only)
  end

  defp valid_threshold_text?(threshold) do
    nonempty_string?(threshold["unit"]) and nonempty_string?(threshold["source_nature"]) and
      nonempty_string?(threshold["default_exceedance_reason"])
  end

  defp valid_threshold_scope?(threshold) do
    paths = threshold["scope"]["paths"]

    is_list(paths) and paths != [] and Enum.all?(paths, &nonempty_string?/1) and
      nonempty_string?(threshold["scope"]["language"])
  end

  defp validate_calibration!(calibration, threshold_id) do
    exact_keys!(calibration, @calibration_keys, "threshold calibration")
    distribution = calibration["distribution"]
    exact_keys!(distribution, @distribution_keys, "calibration distribution")

    points =
      validate_entries!(distribution["points"], @distribution_point_keys, "distribution point", fn point ->
        nonempty_string?(point["statistic"]) and sample_value?(point["value"])
      end)

    valid? =
      nonempty_string?(calibration["method"]) and nonempty_string?(calibration["sample"]) and
        sample_value?(calibration["sample_value"]) and valid_date?(calibration["date"]) and
        nonempty_string?(distribution["population"]) and points != []

    unless valid?, do: raise(ArgumentError, "invalid calibration for #{threshold_id}")
  end

  defp validate_gates!(gates, thresholds, root) when is_list(gates) and gates != [] do
    active_ids = thresholds |> Enum.filter(&(&1["status"] == "enforced")) |> Enum.map(& &1["id"])

    gates =
      Enum.map(gates, fn gate ->
        exact_keys!(gate, @gate_keys, "gate mapping")
        validate_gate!(gate, active_ids, root)
        gate
      end)

    ensure_unique!(Enum.map(gates, & &1["id"]), "gate ids")
    mapped_ids = Enum.flat_map(gates, & &1["thresholds"])

    if Enum.sort(mapped_ids) != Enum.sort(active_ids) or length(mapped_ids) != length(Enum.uniq(mapped_ids)) do
      raise ArgumentError, "each enforced threshold must map to exactly one fast-chain checker"
    end

    gates
  end

  defp validate_gates!(value, _thresholds, _root),
    do: raise(ArgumentError, "gates must be a non-empty list: #{inspect(value)}")

  defp validate_gate!(gate, active_ids, root) do
    unless valid_gate_mapping?(gate, active_ids),
      do: raise(ArgumentError, "invalid gate mapping #{inspect(gate["id"])}")

    implementation = Path.join(root, gate["implementation"])
    fast_chain = Path.join(root, gate["fast_chain"])

    unless File.regular?(implementation) and File.regular?(fast_chain) and
             String.contains?(File.read!(fast_chain), gate["checker"]) do
      raise ArgumentError, "gate #{gate["id"]} must exist and run in its fast chain"
    end
  end

  defp valid_gate_mapping?(gate, active_ids) do
    Enum.all?([
      nonempty_string?(gate["id"]),
      nonempty_string?(gate["checker"]),
      nonempty_string?(gate["implementation"]),
      nonempty_string?(gate["fast_chain"]),
      valid_gate_thresholds?(gate["thresholds"], active_ids)
    ])
  end

  defp valid_gate_thresholds?(thresholds, active_ids) when is_list(thresholds) do
    Enum.all?(thresholds, &(&1 in active_ids)) and length(thresholds) == length(Enum.uniq(thresholds))
  end

  defp valid_gate_thresholds?(_thresholds, _active_ids), do: false

  defp validate_specification!(specification, gates) do
    exact_keys!(specification, @specification_keys, "specification")
    gate_ids = MapSet.new(gates, & &1["id"])

    changes =
      validate_entries!(specification["changes"], @change_keys, "specification change", fn change ->
        nonempty_string?(change["version"]) and valid_date?(change["effective_on"]) and
          MapSet.member?(gate_ids, change["gate"]) and nonempty_string?(change["summary"])
      end)

    current? =
      nonempty_string?(specification["version"]) and valid_date?(specification["effective_on"]) and
        Enum.any?(changes, fn change ->
          change["version"] == specification["version"] and
            change["effective_on"] == specification["effective_on"]
        end)

    unless current?, do: raise(ArgumentError, "current specification version must have a matching gate change")
    Map.put(specification, "changes", changes)
  end

  defp validate_entries!(entries, keys, label, valid?) when is_list(entries) do
    Enum.map(entries, fn entry ->
      exact_keys!(entry, keys, label)
      unless valid?.(entry), do: raise(ArgumentError, "invalid #{label}: #{inspect(entry)}")
      entry
    end)
  end

  defp validate_entries!(value, _keys, label, _valid?),
    do: raise(ArgumentError, "#{label} entries must be a list: #{inspect(value)}")

  defp resolve_scope!(root, scope) do
    tracked = tracked_paths!(root)
    handwritten = Enum.map(scope["handwritten"], &Map.put(&1, "category", "handwritten"))
    classifiers = handwritten ++ scope["excluded"]

    {included, excluded} =
      Enum.reduce(tracked, {[], []}, fn path, {included, excluded} ->
        case Enum.filter(classifiers, &glob_match?(path, &1["path"])) do
          [%{"category" => "handwritten"}] -> {[path | included], excluded}
          [%{} = entry] -> {included, [Map.put(entry, "tracked_path", path) | excluded]}
          [] -> raise ArgumentError, "unclassified tracked path: #{path}"
          matches -> raise ArgumentError, "tracked path matches multiple scope entries: #{path} #{inspect(Enum.map(matches, & &1["path"]))}"
        end
      end)

    %{tracked: tracked, included: Enum.sort(included), excluded: Enum.sort_by(excluded, & &1["tracked_path"])}
  end

  defp tracked_paths!(root) do
    case System.cmd("git", ["-C", root, "ls-files", "-z"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\0", trim: true) |> Enum.sort()
      {output, status} -> raise ArgumentError, "git ls-files failed with status #{status}: #{String.trim(output)}"
    end
  end

  defp measure_threshold(root, scope, %{"kind" => "file_lines"} = threshold) do
    for path <- scoped_paths(scope, threshold),
        do: %{threshold: threshold, target: path, value: line_count(Path.join(root, path))}
  end

  defp measure_threshold(root, scope, %{"kind" => kind} = threshold)
       when kind in ~w(function_lines nesting_depth identifier_occurrences) do
    source_measurements(root, scope, threshold)
  end

  defp measure_threshold(_root, _scope, %{"kind" => "recorded_sample"} = threshold) do
    [
      %{
        threshold: threshold,
        target: List.first(threshold["scope"]["paths"]),
        value: threshold["calibration"]["sample_value"]
      }
    ]
  end

  defp source_measurements(root, scope, %{"kind" => "identifier_occurrences"} = threshold) do
    {identifiers, errors} =
      Enum.reduce(scoped_paths(scope, threshold), {[], []}, fn path, {identifiers, errors} ->
        case quoted(Path.join(root, path)) do
          {:ok, ast} -> {identifiers ++ declared_identifiers(ast), errors}
          {:error, reason} -> {identifiers, [{path, reason} | errors]}
        end
      end)

    measurements =
      identifiers
      |> Enum.frequencies()
      |> Enum.map(fn {name, count} -> %{threshold: threshold, target: name, value: count} end)

    measurements ++ Enum.map(errors, &measurement_error(threshold, &1))
  end

  defp source_measurements(root, scope, threshold) do
    Enum.flat_map(scoped_paths(scope, threshold), fn path ->
      case quoted(Path.join(root, path)) do
        {:ok, ast} -> ast_measurements(threshold, path, ast)
        {:error, reason} -> [measurement_error(threshold, {path, reason})]
      end
    end)
  end

  defp ast_measurements(%{"kind" => "function_lines"} = threshold, path, ast) do
    for {name, arity, line, end_line, _body} <- definitions(ast) do
      %{threshold: threshold, target: "#{path}:#{name}/#{arity}:#{line}", value: end_line - line + 1}
    end
  end

  defp ast_measurements(%{"kind" => "nesting_depth"} = threshold, path, ast) do
    for {name, arity, line, _end_line, body} <- definitions(ast) do
      %{threshold: threshold, target: "#{path}:#{name}/#{arity}:#{line}", value: nesting_depth(body, 0)}
    end
  end

  defp quoted(path) do
    path |> File.read!() |> Code.string_to_quoted(columns: true, token_metadata: true)
  end

  defp definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [{:when, _, [{name, _, args} | _]}, body]} = node, acc when kind in [:def, :defp] ->
          {node, [definition(name, args, meta, body) | acc]}

        {kind, meta, [{name, _, args}, body]} = node, acc when kind in [:def, :defp] ->
          {node, [definition(name, args, meta, body) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(definitions)
  end

  defp definition(name, args, meta, body) do
    line = Keyword.fetch!(meta, :line)
    end_line = metadata_line(meta, :end) || metadata_line(meta, :end_of_expression) || line
    {name, length(args || []), line, end_line, Keyword.fetch!(body, :do)}
  end

  defp metadata_line(meta, key), do: meta |> Keyword.get(key, []) |> Keyword.get(:line)

  defp declared_identifiers(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, names ->
          {node, [List.last(parts) |> to_string() | names]}

        {kind, _, [{:when, _, [{name, _, _} | _]}, _]} = node, names when kind in [:def, :defp] ->
          {node, [to_string(name) | names]}

        {kind, _, [{name, _, _}, _]} = node, names when kind in [:def, :defp] ->
          {node, [to_string(name) | names]}

        node, names ->
          {node, names}
      end)

    names
  end

  defp nesting_depth({form, _, args}, depth) when form in @nested_forms do
    max(depth + 1, children_depth(args, depth + 1))
  end

  defp nesting_depth({_form, _, args}, depth) when is_list(args), do: children_depth(args, depth)
  defp nesting_depth({_key, value}, depth), do: nesting_depth(value, depth)
  defp nesting_depth(list, depth) when is_list(list), do: children_depth(list, depth)
  defp nesting_depth(_value, depth), do: depth

  defp children_depth(children, depth) do
    Enum.reduce(children, depth, fn child, maximum -> max(maximum, nesting_depth(child, depth)) end)
  end

  defp measurement_error(threshold, {path, reason}) do
    %{threshold: threshold, target: path, error: "parse error: #{inspect(reason)}"}
  end

  defp scoped_paths(scope, threshold) do
    scope.included
    |> Enum.filter(fn path -> Enum.any?(threshold["scope"]["paths"], &glob_match?(path, &1)) end)
    |> Enum.sort()
  end

  defp glob_match?(path, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^#{regex}$"), path)
  end

  defp line_count(path) do
    content = File.read!(path)
    newline_count = content |> :binary.matches("\n") |> length()
    if content == "" or String.ends_with?(content, "\n"), do: newline_count, else: newline_count + 1
  end

  defp classify_threshold_measurements(measurements) do
    Enum.reduce(measurements, {[], []}, fn
      %{error: error, threshold: threshold, target: target}, {findings, errors} ->
        {findings, ["#{threshold["id"]}:#{target} #{error}" | errors]}

      %{threshold: threshold, target: target, value: value}, {findings, errors} ->
        threshold_finding = classify_measurement(threshold, target, value)
        if threshold_finding, do: {[threshold_finding | findings], errors}, else: {findings, errors}
    end)
  end

  defp classify_measurement(threshold, target, value) do
    cond do
      threshold["status"] == "record_only" ->
        threshold_finding(
          threshold,
          target,
          value,
          nil,
          "observation",
          "record_only",
          threshold["calibration"]["sample"]
        )

      integer_threshold?(threshold["redline"]) and value > threshold["redline"] ->
        threshold_finding(
          threshold,
          target,
          value,
          threshold["redline"],
          "redline",
          "failure",
          "active redline exceeded"
        )

      integer_threshold?(threshold["default"]) and value > threshold["default"] ->
        threshold_finding(
          threshold,
          target,
          value,
          threshold["default"],
          "default",
          "justified",
          threshold["default_exceedance_reason"]
        )

      true ->
        nil
    end
  end

  defp threshold_finding(threshold, target, value, limit, tier, status, reason) do
    %{
      "threshold" => threshold["id"],
      "target" => target,
      "value" => value,
      "limit" => limit,
      "tier" => tier,
      "status" => status,
      "reason" => reason
    }
  end

  defp waterline(registry, measurements) do
    file_lines = Enum.find(registry["thresholds"], &(&1["id"] == "file_lines"))

    maximum =
      measurements
      |> Enum.filter(&(&1.threshold["id"] == "file_lines" and Map.has_key?(&1, :value)))
      |> Enum.map(& &1.value)
      |> Enum.max(fn -> 0 end)

    %{
      "baseline_remaining" => 0,
      "file_lines_headroom" => file_lines["redline"] - maximum
    }
  end

  defp governance_summary(registry) do
    specification = registry["specification"]

    %{
      "version" => specification["version"],
      "effective_on" => specification["effective_on"],
      "clauses" => length(registry["clauses"]),
      "gates" => Enum.map(registry["gates"], & &1["id"])
    }
  end

  defp scope_summary(root, scope) do
    excluded_counts =
      Map.new(@exclusion_categories, fn category ->
        {category, Enum.count(scope.excluded, &(&1["category"] == category))}
      end)

    %{
      "tracked" => length(scope.tracked),
      "handwritten" => length(scope.included),
      "excluded" => length(scope.excluded),
      "handwritten_lines" => Enum.sum(Enum.map(scope.included, &line_count(Path.join(root, &1)))),
      "excluded_by_category" => excluded_counts
    }
  end

  defp report_summary(registry, findings, errors, waterline) do
    %{
      "thresholds" => length(registry["thresholds"]),
      "active_thresholds" => Enum.count(registry["thresholds"], &(&1["status"] == "enforced")),
      "record_only_thresholds" => Enum.count(registry["thresholds"], &(&1["status"] == "record_only")),
      "failures" => Enum.count(findings, &(&1["status"] == "failure")) + length(errors),
      "baseline_remaining" => waterline["baseline_remaining"],
      "default_notices" => Enum.count(findings, &(&1["tier"] == "default")),
      "observations" => Enum.count(findings, &(&1["status"] == "record_only")),
      "errors" => length(errors)
    }
  end

  defp yaml_map!(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, value} when is_map(value) -> value
      {:ok, _value} -> raise ArgumentError, "#{path} must contain one map document"
      {:error, reason} -> raise ArgumentError, "invalid YAML in #{path}: #{inspect(reason)}"
    end
  end

  defp exact_keys!(map, keys, label) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(keys)
    if actual != expected, do: raise(ArgumentError, "#{label} requires exactly #{inspect(expected)}; got #{inspect(actual)}")
  end

  defp exact_keys!(value, _keys, label),
    do: raise(ArgumentError, "#{label} must be a map; got #{inspect(value)}")

  defp ensure_unique!(values, label) do
    if length(values) != length(Enum.uniq(values)), do: raise(ArgumentError, "duplicate #{label}")
  end

  defp threshold?(value), do: integer_threshold?(value) or value == "pending"
  defp integer_threshold?(value), do: is_integer(value) and value >= 0
  defp sample_value?(value), do: (is_number(value) and value >= 0) or value == "pending"
  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_date?(value) when is_binary(value) do
    match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp valid_date?(_value), do: false
end
