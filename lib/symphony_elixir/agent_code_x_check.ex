defmodule SymphonyElixir.AgentCodeXCheck do
  @moduledoc """
  Validates the repository's Agent-facing code X-conformance record.
  """

  @record_path "docs/agent-facing-code-x-conformance.md"
  @clause_ids ~w(X-01 X-02 X-03 X-04 X-05)
  @checker_ids [
    "mix agent_code.check",
    "mix agent_code_x.check",
    "mix docs.check",
    "mix docs.drift",
    "mix pr_body.check",
    "mix specs.check",
    "scripts/docs_drift_pr_linkage.sh",
    "scripts/negative_assertion_inventory.exs"
  ]
  @top_keys ~w(schema clauses checkers ratchet status_counts)
  @clause_keys ~w(id threshold baseline_status final_status evidence execution_kind test_layer execution remediation_plan not_applicable_reason)
  @checker_keys ~w(id test_layer focused_test disagreement_count sample_count disagreement_rate)
  @ratchet_keys ~w(warning_command warning_result manual_sample_count initial_findings initial_finding_count false_positive_count false_positive_rate baseline_remaining hardening_criterion hardening_event)
  @status_keys ~w(satisfied partially_satisfied not_satisfied not_applicable)
  @statuses @status_keys
  @record_pattern ~r/<!-- agent-code-x-record:start -->\s*```yaml\s*(.*?)\s*```\s*<!-- agent-code-x-record:end -->/s

  @type report :: %{
          required(String.t()) => term()
        }

  @spec check(keyword()) :: report()
  def check(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    record_path = Keyword.get(opts, :record, @record_path)

    {record, load_errors} = load_record(Path.join(root, record_path))
    errors = Enum.sort(load_errors ++ validate_record(record, root))
    baseline_remaining = baseline_remaining(record)

    %{
      "schema" => "agent-facing-code-x-report",
      "status" => if(errors == [], do: "pass", else: "fail"),
      "baseline_remaining" => baseline_remaining,
      "summary" => %{
        "clauses" => count_rows(record["clauses"]),
        "checkers" => count_rows(record["checkers"]),
        "failures" => length(errors)
      },
      "errors" => errors
    }
  end

  @spec exit_code(report()) :: 0 | 1
  def exit_code(%{"status" => "pass"}), do: 0
  def exit_code(%{"status" => "fail"}), do: 1

  @spec human_output(report()) :: String.t()
  def human_output(report) do
    summary = report["summary"]

    waterline =
      "agent_code_x.check: #{String.upcase(report["status"])} " <>
        "clauses=#{summary["clauses"]} checkers=#{summary["checkers"]} " <>
        "failures=#{summary["failures"]} baseline_remaining=#{format_waterline(report["baseline_remaining"])}"

    Enum.join([waterline | report["errors"]], "\n")
  end

  defp load_record(path) do
    case File.read(path) do
      {:ok, content} -> parse_record(content)
      {:error, :enoent} -> {%{}, ["record.file: missing #{path}"]}
      {:error, reason} -> {%{}, ["record.file: cannot read #{path}: #{inspect(reason)}"]}
    end
  end

  defp parse_record(content) do
    case Regex.run(@record_pattern, content) do
      [_, yaml] -> parse_yaml(yaml)
      nil -> {%{}, ["record.machine_record: missing tagged YAML block"]}
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, record} when is_map(record) -> {record, []}
      {:ok, value} -> {%{}, ["record.machine_record: expected one map, got #{inspect(value)}"]}
      {:error, reason} -> {%{}, ["record.machine_record: invalid YAML: #{inspect(reason)}"]}
    end
  end

  defp validate_record(record, root) when is_map(record) do
    exact_keys(record, @top_keys, "record") ++
      schema_errors(record) ++
      validate_clauses(record["clauses"]) ++
      validate_checkers(record["checkers"], root) ++
      validate_ratchet(record["ratchet"]) ++
      validate_status_counts(record["status_counts"], record["clauses"])
  end

  defp schema_errors(%{"schema" => "agent-facing-code-x-conformance"}), do: []
  defp schema_errors(_record), do: ["record.schema: expected agent-facing-code-x-conformance"]

  defp validate_clauses(rows) when is_list(rows) do
    row_shape_errors(rows, "clauses") ++
      validate_expected_rows(rows, @clause_ids, "clause", &validate_clause/1)
  end

  defp validate_clauses(_rows), do: ["record.clauses: must be a list"]

  defp validate_clause(clause) do
    id = clause["id"]

    exact_keys(clause, @clause_keys, "#{id}.fields") ++
      boolean_error(clause["threshold"], "#{id}.threshold") ++
      status_error(clause["baseline_status"], "#{id}.baseline_status") ++
      status_error(clause["final_status"], "#{id}.final_status") ++
      nonempty_error(clause["evidence"], "#{id}.evidence") ++
      execution_kind_errors(clause) ++
      layer_error(clause["test_layer"], "#{id}.test_layer") ++
      nonempty_error(clause["execution"], "#{id}.execution") ++
      disposition_errors(clause)
  end

  defp execution_kind_errors(clause) do
    id = clause["id"]
    kind = clause["execution_kind"]
    layer = clause["test_layer"]

    cond do
      layer not in [1, 2, 3, 4] -> []
      kind == "machine_check" and layer in [1, 2] -> []
      kind == "runtime_behavior" and layer in [3, 4] -> []
      kind == "machine_check" -> ["#{id}.test_layer: machine_check requires Layer 1 or 2"]
      kind == "runtime_behavior" -> ["#{id}.test_layer: runtime_behavior requires Layer 3 or 4"]
      true -> ["#{id}.execution_kind: expected machine_check or runtime_behavior"]
    end
  end

  defp disposition_errors(clause) do
    statuses = [clause["baseline_status"], clause["final_status"]]
    id = clause["id"]

    plan_errors =
      if Enum.any?(statuses, &(&1 in ["partially_satisfied", "not_satisfied"])),
        do: nonempty_error(clause["remediation_plan"], "#{id}.remediation_plan"),
        else: []

    reason_errors =
      if "not_applicable" in statuses,
        do: nonempty_error(clause["not_applicable_reason"], "#{id}.not_applicable_reason"),
        else: []

    plan_errors ++ reason_errors
  end

  defp validate_checkers(rows, root) when is_list(rows) do
    row_shape_errors(rows, "checkers") ++
      validate_expected_rows(rows, @checker_ids, "checker", &validate_checker(&1, root))
  end

  defp validate_checkers(_rows, _root), do: ["record.checkers: must be a list"]

  defp validate_checker(checker, root) do
    id = checker["id"]

    exact_keys(checker, @checker_keys, "#{id}.fields") ++
      checker_layer_errors(checker) ++
      focused_test_errors(checker, root) ++
      calibration_errors(checker)
  end

  defp checker_layer_errors(%{"test_layer" => 1}), do: []
  defp checker_layer_errors(%{"id" => id}), do: ["#{id}.test_layer: checker must be Layer 1"]

  defp focused_test_errors(checker, root) do
    id = checker["id"]
    path = checker["focused_test"]

    case nonempty_error(path, "#{id}.focused_test") do
      [] -> if File.regular?(Path.join(root, path)), do: [], else: ["#{id}.focused_test: file not found: #{path}"]
      errors -> errors
    end
  end

  defp calibration_errors(checker) do
    id = checker["id"]
    disagreements = checker["disagreement_count"]
    samples = checker["sample_count"]
    rate = checker["disagreement_rate"]

    cond do
      not is_integer(disagreements) or disagreements < 0 ->
        ["#{id}.disagreement_count: expected a non-negative integer"]

      not is_integer(samples) or samples <= 0 ->
        ["#{id}.sample_count: expected a positive integer"]

      disagreements > samples ->
        ["#{id}.disagreement_count: cannot exceed sample_count"]

      not is_number(rate) ->
        ["#{id}.disagreement_rate: expected a numeric ratio"]

      rate != disagreements / samples ->
        ["#{id}.disagreement_rate: expected #{disagreements / samples}"]

      true ->
        []
    end
  end

  defp validate_ratchet(ratchet) when is_map(ratchet) do
    exact_keys(ratchet, @ratchet_keys, "ratchet.fields") ++
      nonempty_error(ratchet["warning_command"], "ratchet.warning_command") ++
      nonempty_error(ratchet["warning_result"], "ratchet.warning_result") ++
      positive_integer_error(ratchet["manual_sample_count"], "ratchet.manual_sample_count") ++
      initial_findings_errors(ratchet) ++
      false_positive_errors(ratchet) ++
      baseline_errors(ratchet["baseline_remaining"]) ++
      exact_value_error(ratchet["hardening_criterion"], "baseline_remaining=0", "ratchet.hardening_criterion") ++
      nonempty_error(ratchet["hardening_event"], "ratchet.hardening_event")
  end

  defp validate_ratchet(_ratchet), do: ["record.ratchet: must be a map"]

  defp initial_findings_errors(ratchet) do
    findings = ratchet["initial_findings"]
    count = ratchet["initial_finding_count"]

    cond do
      not is_list(findings) or not Enum.all?(findings, &nonempty_string?/1) ->
        ["ratchet.initial_findings: expected a list of exact non-empty identities"]

      length(findings) != length(Enum.uniq(findings)) ->
        ["ratchet.initial_findings: identities must be unique"]

      not is_integer(count) or count != length(findings) ->
        ["ratchet.initial_finding_count: expected #{length(findings)}"]

      true ->
        []
    end
  end

  defp false_positive_errors(ratchet) do
    samples = ratchet["manual_sample_count"]
    count = ratchet["false_positive_count"]
    rate = ratchet["false_positive_rate"]

    nonnegative_integer_error(count, "ratchet.false_positive_count") ++
      upper_bound_error(count, samples, "ratchet.false_positive_count", "manual_sample_count") ++
      ratio_error(rate, count, samples, "ratchet.false_positive_rate")
  end

  defp baseline_errors(0), do: []

  defp baseline_errors(value) when is_integer(value) and value > 0,
    do: ["ratchet.baseline_remaining: hard gate requires 0, got #{value}"]

  defp baseline_errors(_value), do: ["ratchet.baseline_remaining: expected a non-negative integer"]

  defp validate_status_counts(counts, clauses) when is_map(counts) and is_list(clauses) do
    exact_keys(counts, @status_keys, "status_counts.fields") ++
      Enum.flat_map(@status_keys, fn status ->
        expected = Enum.count(clauses, &(is_map(&1) and &1["final_status"] == status))
        exact_value_error(counts[status], expected, "status_counts.#{status}")
      end) ++
      exact_value_error(Enum.sum(for value <- Map.values(counts), is_integer(value), do: value), 5, "status_counts.total")
  end

  defp validate_status_counts(_counts, _clauses), do: ["record.status_counts: must be a map"]

  defp validate_expected_rows(rows, expected_ids, label, validator) do
    valid_rows = Enum.filter(rows, &is_map/1)
    actual_ids = Enum.map(valid_rows, & &1["id"])

    expected_errors =
      Enum.flat_map(expected_ids, fn id ->
        case Enum.filter(valid_rows, &(&1["id"] == id)) do
          [] -> ["#{id}: missing #{label}"]
          [row] -> validator.(row)
          _rows -> ["#{id}: duplicate #{label}"]
        end
      end)

    unexpected_errors =
      actual_ids
      |> Enum.reject(&(&1 in expected_ids))
      |> Enum.uniq()
      |> Enum.map(&"#{inspect(&1)}: unexpected #{label}")

    expected_errors ++ unexpected_errors
  end

  defp row_shape_errors(rows, label) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {row, _index} when is_map(row) -> []
      {_row, index} -> ["#{label}[#{index}]: must be a map"]
    end)
  end

  defp exact_keys(map, expected, field) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(expected)
    if actual == expected, do: [], else: ["#{field}: expected exactly #{inspect(expected)}, got #{inspect(actual)}"]
  end

  defp boolean_error(value, _field) when is_boolean(value), do: []
  defp boolean_error(_value, field), do: ["#{field}: expected true or false"]

  defp status_error(value, _field) when value in @statuses, do: []
  defp status_error(_value, field), do: ["#{field}: expected one of #{Enum.join(@statuses, ", ")}"]

  defp layer_error(value, _field) when value in [1, 2, 3, 4], do: []
  defp layer_error(_value, field), do: ["#{field}: expected one of 1, 2, 3, 4"]

  defp positive_integer_error(value, _field) when is_integer(value) and value > 0, do: []
  defp positive_integer_error(_value, field), do: ["#{field}: expected a positive integer"]

  defp nonnegative_integer_error(value, _field) when is_integer(value) and value >= 0, do: []
  defp nonnegative_integer_error(_value, field), do: ["#{field}: expected a non-negative integer"]

  defp upper_bound_error(value, maximum, _field, _maximum_field)
       when is_integer(value) and is_integer(maximum) and value <= maximum,
       do: []

  defp upper_bound_error(value, maximum, field, maximum_field)
       when is_integer(value) and is_integer(maximum),
       do: ["#{field}: cannot exceed #{maximum_field}"]

  defp upper_bound_error(_value, _maximum, _field, _maximum_field), do: []

  defp ratio_error(rate, numerator, denominator, field)
       when is_number(rate) and is_integer(numerator) and is_integer(denominator) and denominator > 0 do
    expected = numerator / denominator
    if rate == expected, do: [], else: ["#{field}: expected #{expected}"]
  end

  defp ratio_error(rate, _numerator, _denominator, field) when not is_number(rate),
    do: ["#{field}: expected a numeric ratio"]

  defp ratio_error(_rate, _numerator, _denominator, _field), do: []

  defp nonempty_error(value, field) when is_binary(value) do
    if byte_size(String.trim(value)) > 0, do: [], else: ["#{field}: must be non-empty"]
  end

  defp nonempty_error(_value, field), do: ["#{field}: must be non-empty"]

  defp exact_value_error(value, value, _field), do: []
  defp exact_value_error(value, expected, field), do: ["#{field}: expected #{inspect(expected)}, got #{inspect(value)}"]

  defp nonempty_string?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp baseline_remaining(%{"ratchet" => %{"baseline_remaining" => value}}), do: value
  defp baseline_remaining(_record), do: nil
  defp count_rows(rows) when is_list(rows), do: length(rows)
  defp count_rows(_rows), do: 0
  defp format_waterline(value) when is_integer(value), do: Integer.to_string(value)
  defp format_waterline(_value), do: "unknown"
end
