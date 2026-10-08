defmodule SymphonyElixir.ObservabilityCheck do
  @moduledoc """
  Enforces the deletion-only observability debt inventory.
  """

  @baseline_path "config/observability_baseline.yml"
  @logger_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @failure_fields [:event, :operation, :location, :expected_shape, :error_code, :retryable]
  @baseline_keys ~w(path identifier reason)

  @type finding :: %{required(String.t()) => String.t()}
  @type report :: %{required(String.t()) => term()}

  @spec check(keyword()) :: report()
  def check(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    baseline_path = Keyword.get(opts, :baseline, @baseline_path)
    findings = source_findings(root)
    {baseline, baseline_errors} = load_baseline(Path.join(root, baseline_path))
    errors = Enum.sort(baseline_errors ++ compare(findings, baseline))

    %{
      "status" => if(errors == [], do: "pass", else: "fail"),
      "findings" => findings,
      "errors" => errors,
      "baseline_remaining" => length(baseline)
    }
  end

  @spec exit_code(report()) :: 0 | 1
  def exit_code(%{"status" => "pass"}), do: 0
  def exit_code(%{"status" => "fail"}), do: 1

  @spec human_output(report()) :: String.t()
  def human_output(report) do
    Enum.join(
      ["observability baseline remaining: #{report["baseline_remaining"]}" | report["errors"]],
      "\n"
    )
  end

  defp source_findings(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&file_findings(&1, root))
    |> assign_duplicate_identifiers()
    |> Enum.sort_by(&identity/1)
  end

  defp file_findings(path, root) do
    relative_path = Path.relative_to(path, root)

    case path |> File.read!() |> Code.string_to_quoted(columns: true, token_metadata: true) do
      {:ok, ast} -> logger_findings(ast, relative_path) ++ silent_error_findings(ast, relative_path)
      {:error, reason} -> [finding(relative_path, "parse_error", "source parse failed: #{inspect(reason)}", inspect(reason), 0)]
    end
  end

  defp logger_findings(ast, path) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Logger]}, level]}, meta, arguments} = node, findings
        when level in @logger_levels ->
          missing = required_logger_fields(level) -- literal_metadata_keys(arguments)

          if missing == [] do
            {node, findings}
          else
            reason = "Logger.#{level} lacks registered metadata: #{Enum.join(missing, ",")}"
            {node, [finding(path, "logger.#{level}", reason, node, meta[:line]) | findings]}
          end

        node, findings ->
          {node, findings}
      end)

    Enum.reverse(findings)
  end

  defp literal_metadata_keys(arguments) when is_list(arguments) and length(arguments) >= 2 do
    case List.last(arguments) do
      metadata when is_list(metadata) ->
        for {key, _value} <- metadata, is_atom(key), do: key

      {:%{}, _, pairs} when is_list(pairs) ->
        for {key, _value} <- pairs, is_atom(key), do: key

      _ ->
        []
    end
  end

  defp literal_metadata_keys(_arguments), do: []

  defp required_logger_fields(level) when level in [:warning, :error, :critical, :alert, :emergency],
    do: @failure_fields

  defp required_logger_fields(_level), do: [:event]

  defp silent_error_findings(ast, path) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:try, _, [parts]} = node, findings when is_list(parts) ->
          findings =
            findings
            |> add_silent_try_clauses(path, Keyword.get(parts, :rescue, []), "silent_rescue")
            |> add_silent_try_clauses(path, Keyword.get(parts, :catch, []), "silent_catch")

          {node, findings}

        parts, findings when is_list(parts) ->
          if Keyword.keyword?(parts) do
            findings =
              findings
              |> add_silent_try_clauses(path, Keyword.get(parts, :rescue, []), "silent_rescue")
              |> add_silent_try_clauses(path, Keyword.get(parts, :catch, []), "silent_catch")

            {parts, findings}
          else
            {parts, findings}
          end

        {:->, meta, [patterns, body]} = node, findings ->
          if error_tuple_pattern?(patterns) and silent_success?(body) do
            reason = "error tuple branch returns success without a registered failure event or typed error"
            {node, [finding(path, "silent_error_branch", reason, node, meta[:line]) | findings]}
          else
            {node, findings}
          end

        node, findings ->
          {node, findings}
      end)

    findings
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.path, &1.kind, &1.digest})
  end

  defp add_silent_try_clauses(findings, path, clauses, kind) when is_list(clauses) do
    Enum.reduce(clauses, findings, fn
      {:->, meta, [_patterns, body]} = node, acc ->
        if silent_success?(body) do
          reason = "#{kind} returns success without a registered failure event or typed error"
          [finding(path, kind, reason, node, meta[:line]) | acc]
        else
          acc
        end

      _clause, acc ->
        acc
    end)
  end

  defp add_silent_try_clauses(findings, _path, _clauses, _kind), do: findings

  defp error_tuple_pattern?(patterns) do
    {_patterns, found?} =
      Macro.prewalk(patterns, false, fn
        {:{}, _, [:error | _]} = node, _found? -> {node, true}
        {:error, _value} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp silent_success?(body) do
    terminal = terminal_expression(body)

    terminal in [:ok, false, nil, "unknown"] and
      not contains_explicit_failure?(body) and
      not contains_registered_failure_event?(body)
  end

  defp terminal_expression({:__block__, _, expressions}) when is_list(expressions),
    do: expressions |> List.last() |> terminal_expression()

  defp terminal_expression(expression), do: expression

  defp contains_explicit_failure?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Kernel]}, name]}, _, _} = node, _found?
        when name in [:raise, :reraise, :throw] ->
          {node, true}

        {name, _, _} = node, _found? when name in [:raise, :reraise, :throw] ->
          {node, true}

        {:{}, _, [:error | _]} = node, _found? ->
          {node, true}

        {:error, _value} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp contains_registered_failure_event?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _, arguments} = node, _found?
        when level in [:warning, :error, :critical, :alert, :emergency] ->
          keys = literal_metadata_keys(arguments)
          {node, @failure_fields -- keys == []}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp finding(path, kind, reason, ast, line) do
    digest = :crypto.hash(:sha256, Macro.to_string(ast)) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    %{path: path, kind: kind, digest: digest, reason: reason, line: line || 0}
  end

  defp assign_duplicate_identifiers(findings) do
    findings
    |> Enum.group_by(&{&1.path, &1.kind, &1.digest})
    |> Enum.flat_map(fn {_key, group} -> assign_group_identifiers(group) end)
  end

  defp assign_group_identifiers(group) do
    duplicate? = length(group) > 1

    group
    |> Enum.sort_by(& &1.line)
    |> Enum.with_index(1)
    |> Enum.map(fn {finding, index} ->
      suffix = if duplicate?, do: ".#{index}", else: ""

      %{
        "path" => finding.path,
        "identifier" => "#{finding.kind}:#{finding.digest}#{suffix}",
        "reason" => finding.reason
      }
    end)
  end

  defp load_baseline(path) do
    case File.read(path) do
      {:ok, content} -> parse_baseline(path, content)
      {:error, :enoent} -> {[], []}
      {:error, reason} -> {[], ["baseline cannot be read: #{path}: #{inspect(reason)}"]}
    end
  end

  defp parse_baseline(path, content) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{"schema" => "observability-baseline", "findings" => entries} = document}
      when is_list(entries) ->
        header_errors = exact_keys(document, ~w(schema findings), "baseline")
        {valid_entries, entry_errors} = validate_entries(entries)
        {valid_entries, header_errors ++ entry_errors ++ ordering_errors(valid_entries)}

      {:ok, _document} ->
        {[], ["baseline must contain exactly schema=observability-baseline and findings: #{path}"]}

      {:error, reason} ->
        {[], ["baseline YAML is invalid: #{path}: #{inspect(reason)}"]}
    end
  end

  defp validate_entries(entries) do
    {valid, errors} =
      entries
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {entry, index}, {valid, errors} ->
        entry_errors = validate_entry(entry, index)
        if entry_errors == [], do: {[entry | valid], errors}, else: {valid, entry_errors ++ errors}
      end)

    valid = Enum.reverse(valid)
    identities = Enum.map(valid, &{&1["path"], &1["identifier"]})

    duplicate_errors =
      identities
      |> Enum.frequencies()
      |> Enum.filter(fn {_identity, count} -> count > 1 end)
      |> Enum.map(fn {{path, identifier}, _count} -> "duplicate baseline entry: #{path}:#{identifier}" end)

    {valid, Enum.sort(errors ++ duplicate_errors)}
  end

  defp validate_entry(entry, index) when is_map(entry) do
    key_errors = exact_keys(entry, @baseline_keys, "baseline finding #{index}")

    value_errors =
      for key <- @baseline_keys,
          value = Map.get(entry, key),
          not (is_binary(value) and String.trim(value) != "") do
        "baseline finding #{index} requires non-empty #{key}"
      end

    key_errors ++ value_errors
  end

  defp validate_entry(_entry, index), do: ["baseline finding #{index} must be a map"]

  defp exact_keys(map, expected, label) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: [],
      else: ["#{label} requires exactly keys: #{Enum.join(expected, ",")}"]
  end

  defp ordering_errors(entries) do
    sorted = Enum.sort_by(entries, &identity/1)
    if entries == sorted, do: [], else: ["baseline findings must be sorted by path, identifier, reason"]
  end

  defp compare(findings, baseline) do
    finding_set = MapSet.new(findings, &identity/1)
    baseline_set = MapSet.new(baseline, &identity/1)

    unbaselined =
      finding_set
      |> MapSet.difference(baseline_set)
      |> Enum.map(fn {path, identifier, reason} -> "unbaselined finding: #{path}:#{identifier}: #{reason}" end)

    stale =
      baseline_set
      |> MapSet.difference(finding_set)
      |> Enum.map(fn {path, identifier, reason} -> "stale baseline entry: #{path}:#{identifier}: #{reason}" end)

    Enum.sort(unbaselined ++ stale)
  end

  defp identity(entry), do: {entry["path"], entry["identifier"], entry["reason"]}
end
