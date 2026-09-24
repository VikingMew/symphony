defmodule SymphonyElixir.AgentCodeCheck do
  @moduledoc """
  Evaluates the repository's agent-facing code threshold registry.
  """

  @registry_path "config/agent_code_thresholds.yml"
  @exemptions_path "config/agent_code_exemptions.yml"
  @rule_ids ~w(file_lines function_lines nesting_depth identifier_occurrences resident_rule_lines full_gate_minutes change_lines)
  @rule_keys ~w(id kind scope unit redline default source_nature evidence_mode status default_exceedance_reason calibration)
  @scope_keys ~w(paths language exclusions)
  @exclusion_keys ~w(path reason)
  @calibration_keys ~w(method sample sample_value date)
  @exemption_keys ~w(rule target owner reason expires_on)
  @nested_forms [:case, :cond, :for, :fn, :if, :receive, :try, :unless, :with]

  @type finding :: %{required(String.t()) => term()}
  @type report :: %{required(String.t()) => term()}

  @spec check(keyword()) :: report()
  def check(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    registry_path = Keyword.get(opts, :registry, @registry_path)
    exemptions_path = Keyword.get(opts, :exemptions, @exemptions_path)
    today = Keyword.get(opts, :today, Date.utc_today())
    registry = load_registry!(Path.join(root, registry_path))
    exemptions = load_exemptions!(Path.join(root, exemptions_path), registry)

    {findings, errors} =
      registry["rules"]
      |> Enum.flat_map(&measure_rule(root, &1))
      |> classify(registry, exemptions, today)

    findings = Enum.sort_by(findings, &{&1["rule"], &1["target"], &1["tier"]})
    errors = Enum.sort(errors)
    failures = Enum.count(findings, &(&1["status"] == "failure")) + length(errors)

    %{
      "schema" => "agent-facing-code-report",
      "status" => if(failures == 0, do: "pass", else: "fail"),
      "summary" => summary(registry, findings, errors),
      "findings" => findings,
      "errors" => errors
    }
  end

  @spec exit_code(report()) :: 0 | 1
  def exit_code(%{"status" => "pass"}), do: 0
  def exit_code(%{"status" => "fail"}), do: 1

  @spec human_output(report()) :: String.t()
  def human_output(report) do
    summary = report["summary"]

    header =
      "agent_code.check: #{String.upcase(report["status"])} " <>
        "(#{summary["rules"]} rules, #{summary["active_rules"]} active, " <>
        "#{summary["failures"]} failures, #{summary["exemptions"]} exemptions, " <>
        "#{summary["default_notices"]} default notices)"

    details =
      report["errors"] ++
        (report["findings"]
         |> Enum.filter(&(&1["status"] == "failure"))
         |> Enum.map(fn finding ->
           "#{finding["rule"]}:#{finding["target"]} value=#{finding["value"]} limit=#{finding["limit"]}"
         end))

    Enum.join([header | details], "\n")
  end

  defp load_registry!(path) do
    registry = yaml_map!(path)
    exact_keys!(registry, ~w(schema owner rules), "registry")

    if registry["schema"] != "agent-facing-code-thresholds" or not is_binary(registry["owner"]) or
         not is_list(registry["rules"]) do
      raise ArgumentError, "invalid agent-facing code registry header"
    end

    rules = Enum.map(registry["rules"], &validate_rule!/1)
    ids = Enum.map(rules, & &1["id"])

    if Enum.sort(ids) != Enum.sort(@rule_ids) or length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "registry must contain each of the seven threshold rules exactly once"
    end

    Map.put(registry, "rules", rules)
  end

  defp validate_rule!(rule) when is_map(rule) do
    exact_keys!(rule, @rule_keys, "rule")
    exact_keys!(rule["scope"], @scope_keys, "rule scope")
    exact_keys!(rule["calibration"], @calibration_keys, "rule calibration")

    valid? =
      Enum.all?([
        rule["id"] in @rule_ids,
        rule["kind"] in ~w(file_lines function_lines nesting_depth identifier_occurrences resident_rule_lines recorded_sample),
        rule["evidence_mode"] in ~w(machine human orientation),
        rule["status"] in ~w(enforced record_only),
        is_list(rule["scope"]["paths"]),
        rule["scope"]["paths"] != [],
        is_binary(rule["scope"]["language"]),
        is_list(rule["scope"]["exclusions"]),
        threshold?(rule["redline"]),
        threshold?(rule["default"]),
        is_binary(rule["source_nature"]),
        is_binary(rule["default_exceedance_reason"])
      ])

    unless valid? do
      raise ArgumentError, "invalid threshold rule #{inspect(rule["id"])}"
    end

    Enum.each(rule["scope"]["exclusions"], fn exclusion ->
      exact_keys!(exclusion, @exclusion_keys, "scope exclusion")

      unless nonempty_string?(exclusion["path"]) and nonempty_string?(exclusion["reason"]) do
        raise ArgumentError, "invalid scope exclusion for #{rule["id"]}"
      end
    end)

    calibration = rule["calibration"]

    valid_calibration? =
      Enum.all?([
        nonempty_string?(calibration["method"]),
        nonempty_string?(calibration["sample"]),
        sample_value?(calibration["sample_value"]),
        valid_date?(calibration["date"])
      ])

    unless valid_calibration? do
      raise ArgumentError, "invalid calibration for #{rule["id"]}"
    end

    rule
  end

  defp validate_rule!(rule), do: raise(ArgumentError, "threshold rule must be a map: #{inspect(rule)}")

  defp load_exemptions!(path, registry) do
    document = yaml_map!(path)
    exact_keys!(document, ~w(schema owner exemptions), "exemption registry")

    if document["schema"] != "agent-facing-code-exemptions" or not is_binary(document["owner"]) or
         not is_list(document["exemptions"]) do
      raise ArgumentError, "invalid agent-facing code exemption registry header"
    end

    active_ids = registry["rules"] |> Enum.filter(&(&1["status"] == "enforced")) |> MapSet.new(& &1["id"])

    exemptions =
      Enum.map(document["exemptions"], fn exemption ->
        exact_keys!(exemption, @exemption_keys, "exemption")

        valid? =
          Enum.all?([
            MapSet.member?(active_ids, exemption["rule"]),
            nonempty_string?(exemption["target"]),
            nonempty_string?(exemption["owner"]),
            nonempty_string?(exemption["reason"]),
            valid_date?(exemption["expires_on"])
          ])

        unless valid? do
          raise ArgumentError, "invalid exemption #{inspect(exemption)}"
        end

        exemption
      end)

    identities = Enum.map(exemptions, &{&1["rule"], &1["target"]})

    if length(identities) != length(Enum.uniq(identities)) do
      raise ArgumentError, "duplicate rule + target exemption identity"
    end

    exemptions
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

  defp exact_keys!(value, _keys, label), do: raise(ArgumentError, "#{label} must be a map; got #{inspect(value)}")

  defp measure_rule(root, %{"kind" => "file_lines"} = rule), do: line_measurements(root, rule)
  defp measure_rule(root, %{"kind" => "resident_rule_lines"} = rule), do: line_measurements(root, rule)

  defp measure_rule(root, %{"kind" => kind} = rule) when kind in ~w(function_lines nesting_depth identifier_occurrences) do
    source_measurements(root, rule)
  end

  defp measure_rule(_root, %{"kind" => "recorded_sample"} = rule) do
    [%{rule: rule, target: List.first(rule["scope"]["paths"]), value: rule["calibration"]["sample_value"]}]
  end

  defp line_measurements(root, rule) do
    for path <- scoped_paths(root, rule), do: %{rule: rule, target: path, value: line_count(Path.join(root, path))}
  end

  defp source_measurements(root, %{"kind" => "identifier_occurrences"} = rule) do
    {identifiers, errors} =
      Enum.reduce(scoped_paths(root, rule), {[], []}, fn path, {identifiers, errors} ->
        case quoted(Path.join(root, path)) do
          {:ok, ast} -> {identifiers ++ declared_identifiers(ast), errors}
          {:error, reason} -> {identifiers, [{path, reason} | errors]}
        end
      end)

    measurements =
      identifiers
      |> Enum.frequencies()
      |> Enum.map(fn {name, count} -> %{rule: rule, target: name, value: count} end)

    measurements ++ Enum.map(errors, &measurement_error(rule, &1))
  end

  defp source_measurements(root, rule) do
    Enum.flat_map(scoped_paths(root, rule), fn path ->
      case quoted(Path.join(root, path)) do
        {:ok, ast} -> ast_measurements(rule, path, ast)
        {:error, reason} -> [measurement_error(rule, {path, reason})]
      end
    end)
  end

  defp ast_measurements(%{"kind" => "function_lines"} = rule, path, ast) do
    for {name, arity, line, end_line, _body} <- definitions(ast) do
      %{rule: rule, target: "#{path}:#{name}/#{arity}:#{line}", value: end_line - line + 1}
    end
  end

  defp ast_measurements(%{"kind" => "nesting_depth"} = rule, path, ast) do
    for {name, arity, line, _end_line, body} <- definitions(ast) do
      %{rule: rule, target: "#{path}:#{name}/#{arity}:#{line}", value: nesting_depth(body, 0)}
    end
  end

  defp quoted(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted(columns: true, token_metadata: true)
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

  defp metadata_line(meta, key) do
    meta |> Keyword.get(key, []) |> Keyword.get(:line)
  end

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

  defp measurement_error(rule, {path, reason}) do
    %{rule: rule, target: path, error: "parse error: #{inspect(reason)}"}
  end

  defp scoped_paths(root, rule) do
    exclusions = rule["scope"]["exclusions"]

    rule["scope"]["paths"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1), match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(fn path -> Enum.any?(exclusions, &glob_match?(path, &1["path"])) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp glob_match?(path, pattern) do
    regex = pattern |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")
    Regex.match?(Regex.compile!("^#{regex}$"), path)
  end

  defp line_count(path) do
    content = File.read!(path)
    newline_count = content |> :binary.matches("\n") |> length()
    if content == "" or String.ends_with?(content, "\n"), do: newline_count, else: newline_count + 1
  end

  defp classify(measurements, _registry, exemptions, today) do
    exemptions = Map.new(exemptions, &{{&1["rule"], &1["target"]}, &1})

    Enum.reduce(measurements, {[], []}, fn
      %{error: error, rule: rule, target: target}, {findings, errors} ->
        {findings, ["#{rule["id"]}:#{target} #{error}" | errors]}

      %{rule: rule, target: target, value: value}, {findings, errors} ->
        finding = classify_measurement(rule, target, value, Map.get(exemptions, {rule["id"], target}), today)
        if finding, do: {[finding | findings], errors}, else: {findings, errors}
    end)
    |> then(fn {findings, errors} -> {findings, stale_exemption_errors(exemptions, measurements) ++ errors} end)
  end

  defp classify_measurement(rule, target, value, exemption, today) do
    cond do
      rule["status"] == "record_only" ->
        finding(rule, target, value, nil, "observation", "record_only", rule["calibration"]["sample"])

      integer_threshold?(rule["redline"]) and value > rule["redline"] ->
        redline_finding(rule, target, value, exemption, today)

      integer_threshold?(rule["default"]) and value > rule["default"] ->
        finding(rule, target, value, rule["default"], "default", "justified", rule["default_exceedance_reason"])

      true ->
        nil
    end
  end

  defp redline_finding(rule, target, value, nil, _today) do
    finding(rule, target, value, rule["redline"], "redline", "failure", "active redline exceeded without an exact exemption")
  end

  defp redline_finding(rule, target, value, exemption, today) do
    expiry = Date.from_iso8601!(exemption["expires_on"])

    if Date.compare(expiry, today) == :lt do
      finding(rule, target, value, rule["redline"], "redline", "failure", "exemption expired on #{exemption["expires_on"]}")
    else
      finding(rule, target, value, rule["redline"], "redline", "exempted", exemption["reason"], exemption)
    end
  end

  defp finding(rule, target, value, limit, tier, status, reason, exemption \\ nil) do
    %{
      "rule" => rule["id"],
      "target" => target,
      "value" => value,
      "limit" => limit,
      "tier" => tier,
      "status" => status,
      "reason" => reason,
      "owner" => exemption && exemption["owner"],
      "expires_on" => exemption && exemption["expires_on"]
    }
  end

  defp stale_exemption_errors(exemptions, measurements) do
    measured = MapSet.new(measurements, fn measurement -> {measurement.rule["id"], measurement.target} end)

    for {identity, _exemption} <- exemptions, not MapSet.member?(measured, identity) do
      {rule, target} = identity
      "#{rule}:#{target} exemption does not match a current measurement"
    end
  end

  defp summary(registry, findings, errors) do
    %{
      "rules" => length(registry["rules"]),
      "active_rules" => Enum.count(registry["rules"], &(&1["status"] == "enforced")),
      "record_only_rules" => Enum.count(registry["rules"], &(&1["status"] == "record_only")),
      "failures" => Enum.count(findings, &(&1["status"] == "failure")) + length(errors),
      "exemptions" => Enum.count(findings, &(&1["status"] == "exempted")),
      "default_notices" => Enum.count(findings, &(&1["tier"] == "default")),
      "observations" => Enum.count(findings, &(&1["status"] == "record_only")),
      "errors" => length(errors)
    }
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
