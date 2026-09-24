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
    write!(root, "exact.sh", String.duplicate("# line\n", 1_000))
    write!(root, "over.sh", String.duplicate("# line\n", 1_001))

    violations = Locality.check_paths(root, ["exact.sh", "over.sh"], config(), ~D[2026-09-24])

    assert violations == [%{path: "over.sh", message: "1001 lines exceeds 1000"}]
  end

  test "measures every clause and accepts the 60-line boundary", %{root: root} do
    source = clause_module(57, 58)
    write!(root, "clauses.ex", source)

    assert [%{path: "clauses.ex", message: message}] =
             Locality.check_paths(root, ["clauses.ex"], config(), ~D[2026-09-24])

    assert message =~ "value/1@"
    assert message =~ "spans 61 lines"
  end

  test "enforces nesting depth two", %{root: root} do
    write!(root, "nested.ex", """
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

    assert [%{message: message}] =
             Locality.check_paths(root, ["nested.ex"], config(), ~D[2026-09-24])

    assert message =~ "nesting depth 3"
  end

  test "rejects a three-call implicit chain and permits a pipeline", %{root: root} do
    write!(root, "calls.ex", """
    defmodule Calls do
      def implicit(value), do: value.one().two().three()
      def explicit(value), do: value |> One.call() |> Two.call() |> Three.call()
    end
    """)

    assert [%{message: message}] =
             Locality.check_paths(root, ["calls.ex"], config(), ~D[2026-09-24])

    assert message =~ "nested remote-call depth 3"
  end

  test "validates generated headers, data exclusions, and stale exclusions", %{root: root} do
    write!(root, "generated.js", "// Generated from: mix assets\n// DO NOT EDIT\nconst value = 1;\n")
    write!(root, "data.js", String.duplicate("value\n", 1_001))

    settings =
      config(%{
        data_paths: ["data.js", "missing.json"],
        generated: [%{path: "generated.js", source: "mix assets"}]
      })

    assert [%{path: "missing.json", message: "data exclusion does not name a tracked file"}] =
             Locality.check_paths(root, ["data.js", "generated.js"], settings, ~D[2026-09-24])

    write!(root, "generated.js", "const value = 1;\n")
    violations = Locality.check_paths(root, ["data.js", "generated.js"], settings, ~D[2026-09-24])
    assert Enum.any?(violations, &String.contains?(&1.message, "Generated from: mix assets"))
    assert Enum.any?(violations, &String.contains?(&1.message, "DO NOT EDIT"))
  end

  test "rejects incomplete, expired, and overlong exception records", %{root: root} do
    write!(root, "long.ex", "# Locality split index: docs/code-locality.md#temporary-clause-splits\n" <> clause_module(59, 1))
    [%{message: message}] = Locality.check_paths(root, ["long.ex"], config(), ~D[2026-09-24])
    [identifier, lines] = Regex.run(~r/^(.+) spans (\d+) lines;/, message, capture: :all_but_first)

    base = %{
      path: "long.ex",
      identifier: identifier,
      lines: String.to_integer(lines),
      split: "Extract a helper.",
      owner: "owner",
      due: ~D[2026-09-23]
    }

    expired = config(%{clause_exceptions: [base]})
    assert Enum.any?(Locality.check_paths(root, ["long.ex"], expired, ~D[2026-09-24]), &String.contains?(&1.message, "expired"))

    overlong = config(%{clause_exceptions: [%{base | due: ~D[2026-10-25]}]})
    assert Enum.any?(Locality.check_paths(root, ["long.ex"], overlong, ~D[2026-09-24]), &String.contains?(&1.message, "more than 30 days"))

    incomplete = config(%{clause_exceptions: [Map.delete(base, :due)]})
    assert Enum.any?(Locality.check_paths(root, ["long.ex"], incomplete, ~D[2026-09-24]), &String.contains?(&1.message, "missing fields"))
  end

  test "returns deterministic violations", %{root: root} do
    write!(root, "b.sh", String.duplicate("b\n", 1_001))
    write!(root, "a.sh", String.duplicate("a\n", 1_001))

    first = Locality.check_paths(root, ["b.sh", "a.sh"], config(), ~D[2026-09-24])
    second = Locality.check_paths(root, ["b.sh", "a.sh"], config(), ~D[2026-09-24])

    assert first == second
    assert Locality.format(first) == Locality.format(second)
    assert Enum.map(first, & &1.path) == ["a.sh", "b.sh"]
  end

  defp clause_module(first_body_lines, second_body_lines) do
    "defmodule Clauses do\n" <>
      clause(:value, :first, first_body_lines) <>
      clause(:value, :second, second_body_lines) <>
      "end\n"
  end

  defp clause(name, argument, body_lines) do
    body = Enum.map_join(1..body_lines, "\n", &"    value_#{&1} = #{&1}")
    "  def #{name}(:#{argument}) do\n#{body}\n    :ok\n  end\n"
  end

  defp config(overrides \\ %{}) do
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

  defp write!(root, path, contents), do: File.write!(Path.join(root, path), contents)
end
