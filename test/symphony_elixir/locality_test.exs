defmodule SymphonyElixir.LocalityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Locality

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-locality-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts exactly 1,000 physical lines and rejects 1,001", %{root: root} do
    write_source!(root, "exact.sh", String.duplicate("# line\n", 1_000))
    write_source!(root, "over.sh", String.duplicate("# line\n", 1_001))

    %{violations: violations} = Locality.check_paths(root, ["exact.sh", "over.sh"], locality_settings())

    assert violations == [%{path: "over.sh", message: "1001 lines exceeds 1000"}]
  end

  test "measures every clause and accepts the 60-line boundary", %{root: root} do
    source = clause_module(57, 58)
    write_source!(root, "clauses.ex", source)

    assert %{violations: [%{path: "clauses.ex", message: message}]} =
             Locality.check_paths(root, ["clauses.ex"], locality_settings())

    assert message =~ "value/1@"
    assert message =~ "spans 61 lines"
  end

  test "enforces nesting depth two", %{root: root} do
    write_source!(root, "nested.ex", """
    defmodule Nested do
      def valid(values) do
        Enum.map(values, fn value ->
          if value, do: value, else: nil
        end)
      end

      def invalid(values) do
        Enum.map(values, fn value ->
          if value do
            case value do
              true -> value
            end
          end
        end)
      end
    end
    """)

    assert %{violations: [%{message: message}]} =
             Locality.check_paths(root, ["nested.ex"], locality_settings())

    assert message =~ "nesting depth 3"
  end

  test "rejects a three-call implicit chain and permits a pipeline", %{root: root} do
    write_source!(root, "calls.ex", """
    defmodule Calls do
      def implicit(value), do: value.one().two().three()
      def explicit(value), do: value |> One.call() |> Two.call() |> Three.call()
    end
    """)

    assert %{violations: [%{message: message}]} =
             Locality.check_paths(root, ["calls.ex"], locality_settings())

    assert message =~ "nested remote-call depth 3"
  end

  test "validates generated headers, data exclusions, and stale exclusions", %{root: root} do
    write_source!(root, "generated.js", "// Generated from: mix assets\n// DO NOT EDIT\nconst value = 1;\n")
    write_source!(root, "data.js", String.duplicate("value\n", 1_001))

    settings =
      locality_settings(%{
        data_paths: ["data.js", "missing.json"],
        generated: [%{path: "generated.js", source: "mix assets"}]
      })

    assert %{violations: [%{path: "missing.json", message: "data exclusion does not name a tracked file"}]} =
             Locality.check_paths(root, ["data.js", "generated.js"], settings)

    write_source!(root, "generated.js", "const value = 1;\n")
    %{violations: violations} = Locality.check_paths(root, ["data.js", "generated.js"], settings)
    assert Enum.any?(violations, &String.contains?(&1.message, "Generated from: mix assets"))
    assert Enum.any?(violations, &String.contains?(&1.message, "DO NOT EDIT"))
  end

  test "matches the dateless clause baseline exactly on path, identifier, and lines", %{root: root} do
    write_source!(root, "long.ex", "# Locality split index: docs/code-locality.md#temporary-clause-splits\n" <> clause_module(59, 1))
    write_source!(root, "other.ex", "# Locality split index: docs/code-locality.md#temporary-clause-splits\n:ok\n")

    %{violations: [%{message: message}]} =
      Locality.check_paths(root, ["long.ex", "other.ex"], locality_settings())

    [identifier, lines] = Regex.run(~r/^(.+) spans (\d+) lines;/, message, capture: :all_but_first)

    base = %{
      path: "long.ex",
      identifier: identifier,
      lines: String.to_integer(lines),
      split: "Extract a helper.",
      owner: "owner"
    }

    paths = ["long.ex", "other.ex"]
    assert Locality.check_paths(root, paths, locality_settings(%{clause_exceptions: [base]})).violations == []

    mismatches = [
      %{base | path: "other.ex"},
      %{base | identifier: identifier <> "-changed"},
      %{base | lines: base.lines + 1}
    ]

    Enum.each(mismatches, fn mismatch ->
      result = Locality.check_paths(root, paths, locality_settings(%{clause_exceptions: [mismatch]}))
      assert Enum.any?(result.violations, &String.contains?(&1.message, "spans #{base.lines} lines"))
    end)

    incomplete = locality_settings(%{clause_exceptions: [Map.delete(base, :owner)]})
    result = Locality.check_paths(root, paths, incomplete)
    assert Enum.any?(result.violations, &String.contains?(&1.message, "missing fields: owner"))
  end

  test "reports the deterministic waterline exactly once", %{root: root} do
    write_source!(root, "long.ex", "# Locality split index: docs/code-locality.md#temporary-clause-splits\n" <> clause_module(59, 1))
    write_source!(root, "largest.sh", String.duplicate("# line\n", 77))

    %{violations: [%{message: message}]} =
      Locality.check_paths(root, ["long.ex", "largest.sh"], locality_settings())

    [identifier, lines] = Regex.run(~r/^(.+) spans (\d+) lines;/, message, capture: :all_but_first)

    exception = %{
      path: "long.ex",
      identifier: identifier,
      lines: String.to_integer(lines),
      split: "Extract a helper.",
      owner: "owner"
    }

    result =
      Locality.check_paths(root, ["long.ex", "largest.sh"], locality_settings(%{clause_exceptions: [exception]}))

    output = Locality.format_report(result)

    assert result.waterline == %{exemptions_remaining: 1, max_file_lines: 77, max_clause_lines: 62}
    assert output =~ "locality_waterline exemptions_remaining=1 max_file_lines=77 max_clause_lines=62"
    assert length(Regex.scan(~r/^locality_waterline /m, output)) == 1
  end

  test "returns deterministic violations", %{root: root} do
    write_source!(root, "b.sh", String.duplicate("b\n", 1_001))
    write_source!(root, "a.sh", String.duplicate("a\n", 1_001))

    first = Locality.check_paths(root, ["b.sh", "a.sh"], locality_settings())
    second = Locality.check_paths(root, ["b.sh", "a.sh"], locality_settings())

    assert first == second
    assert Locality.format_report(first) == Locality.format_report(second)
    assert Enum.map(first.violations, & &1.path) == ["a.sh", "b.sh"]
  end

  defp clause_module(first_body_lines, second_body_lines) do
    "defmodule Clauses do\n" <>
      source_clause(:value, :first, first_body_lines) <>
      source_clause(:value, :second, second_body_lines) <>
      "end\n"
  end

  defp source_clause(name, argument, body_lines) do
    body = Enum.map_join(1..body_lines, "\n", &"    value_#{&1} = #{&1}")
    "  def #{name}(:#{argument}) do\n#{body}\n    :ok\n  end\n"
  end

  defp locality_settings(overrides \\ %{}) do
    Map.merge(
      %{
        code_extensions: ~w(.ex .exs .js .sh),
        code_basenames: [],
        data_paths: [],
        generated: [],
        clause_exceptions: []
      },
      overrides
    )
  end

  defp write_source!(root, path, contents), do: File.write!(Path.join(root, path), contents)
end
