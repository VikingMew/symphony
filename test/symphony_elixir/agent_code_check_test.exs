defmodule SymphonyElixir.AgentCodeCheckTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentCodeCheck

  setup do
    original = File.cwd!()
    root = Path.join(original, "_build/agent-code-check-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    write(root, "scripts/check.sh", "mix agent_code.check\n")
    write(root, "lib/mix/tasks/agent_code.check.ex", "defmodule FixtureTask do\nend\n")

    registry = YamlElixir.read_from_file!("config/agent_code_governance.yml")
    write_registry(root, registry)
    track(root)

    on_exit(fn -> File.rm_rf!(root) end)
    %{registry: registry, root: root}
  end

  test "enforced file redlines pass at the boundary and fail new violations directly", %{
    registry: registry,
    root: root
  } do
    write(root, "lib/boundary.ex", lines(5))
    write_registry(root, registry, active: ["file_lines"], rule_limits: %{"file_lines" => {5, 3}})
    track(root)

    boundary = AgentCodeCheck.check(root: root)
    assert boundary["status"] == "pass"
    assert AgentCodeCheck.exit_code(boundary) == 0

    write(root, "lib/boundary.ex", lines(6))
    track(root)
    exceeded = AgentCodeCheck.check(root: root)

    assert Enum.map(failures(exceeded), &{&1["threshold"], &1["value"], &1["limit"]}) == [
             {"file_lines", 6, 5}
           ]

    assert AgentCodeCheck.exit_code(exceeded) == 1
  end

  test "function and nesting measurements use AST boundaries", %{registry: registry, root: root} do
    write(root, "lib/sample.ex", """
    defmodule Sample do
      def boundary do
        if true do
          :ok
        end
      end

      def exceeded do
        if true do
          if true do
            :ok
          end
        end
      end
    end
    """)

    write_registry(root, registry,
      active: ~w(function_lines nesting_depth),
      rule_limits: %{"function_lines" => {5, 2}, "nesting_depth" => {1, 0}}
    )

    track(root)
    report = AgentCodeCheck.check(root: root)

    assert [%{"threshold" => "function_lines", "value" => 7}, %{"threshold" => "nesting_depth", "value" => 2}] =
             failures(report)
  end

  test "identifier occurrence redline passes at five and fails at six", %{
    registry: registry,
    root: root
  } do
    write(root, "lib/five.ex", repeated_definitions(5))

    write_registry(root, registry,
      active: ["identifier_occurrences"],
      rule_limits: %{"identifier_occurrences" => {5, 1}}
    )

    track(root)
    assert AgentCodeCheck.check(root: root)["status"] == "pass"

    write(root, "lib/six.ex", repeated_definitions(1, 6))
    track(root)
    exceeded = AgentCodeCheck.check(root: root)

    assert [%{"threshold" => "identifier_occurrences", "target" => "shared", "value" => 6}] =
             failures(exceeded)
  end

  test "one closed scope drives sorted source list and line statistics", %{root: root} do
    write(root, "README.md", "one\ntwo\n")
    write(root, "lib/included.ex", "line\n")
    write(root, "mix.lock", "%{}\n")
    track(root)

    list = AgentCodeCheck.source_list(root: root)
    stats = AgentCodeCheck.source_stats(root: root)

    assert list["paths"] == Enum.sort(list["paths"])
    assert list["summary"] == stats["summary"]
    assert stats["summary"]["tracked"] == stats["summary"]["handwritten"] + stats["summary"]["excluded"]
    assert "lib/included.ex" in list["paths"]
    refute "mix.lock" in list["paths"]

    expected_lines =
      list["paths"]
      |> Enum.map(&File.read!(Path.join(root, &1)))
      |> Enum.map(&fixture_source_line_count/1)
      |> Enum.sum()

    assert stats["summary"]["handwritten_lines"] == expected_lines
  end

  test "unclassified and multiply classified tracked paths fail with their path", %{
    registry: registry,
    root: root
  } do
    write(root, "mystery.bin", "not classified\n")
    track(root)

    assert_raise ArgumentError, ~r/unclassified tracked path: mystery.bin/, fn ->
      AgentCodeCheck.source_stats(root: root)
    end

    File.rm!(Path.join(root, "mystery.bin"))
    handwritten = registry["scope"]["handwritten"] ++ [%{"path" => "lib/**"}]
    write_registry(root, put_in(registry, ["scope", "handwritten"], handwritten))
    track(root)

    assert_raise ArgumentError, ~r/tracked path matches multiple scope entries: lib\/mix\/tasks/, fn ->
      AgentCodeCheck.source_stats(root: root)
    end
  end

  test "G clauses require exact identities, legal tiers, and evidence methods", %{
    registry: registry,
    root: root
  } do
    invalid_tier = put_in(registry, ["clauses", Access.at(0), "evidence_tier"], "preference")
    write_registry(root, invalid_tier)
    track(root)
    assert_raise ArgumentError, ~r/invalid G clause/, fn -> AgentCodeCheck.check(root: root) end

    missing_method = update_in(registry, ["clauses", Access.at(0)], &Map.delete(&1, "evidence_method"))
    write_registry(root, missing_method)
    track(root)
    assert_raise ArgumentError, ~r/G clause requires exactly/, fn -> AgentCodeCheck.check(root: root) end

    duplicate = put_in(registry, ["clauses", Access.at(1), "id"], "G-01")
    write_registry(root, duplicate)
    track(root)
    assert_raise ArgumentError, ~r/G-01 through G-08 exactly once/, fn -> AgentCodeCheck.check(root: root) end
  end

  test "calibration distributions, versions, and hard-gate mappings are strict", %{
    registry: registry,
    root: root
  } do
    no_distribution = update_in(registry, ["thresholds", Access.at(0), "calibration"], &Map.delete(&1, "distribution"))
    write_raw_registry(root, no_distribution)
    track(root)
    assert_raise ArgumentError, ~r/calibration requires exactly/, fn -> AgentCodeCheck.check(root: root) end

    no_current_change = put_in(registry, ["specification", "version"], "missing")
    write_raw_registry(root, no_current_change)
    track(root)
    assert_raise ArgumentError, ~r/current specification version/, fn -> AgentCodeCheck.check(root: root) end

    no_threshold_mapping = put_in(registry, ["gates", Access.at(0), "thresholds"], [])
    write_raw_registry(root, no_threshold_mapping)
    track(root)
    assert_raise ArgumentError, ~r/each enforced threshold/, fn -> AgentCodeCheck.check(root: root) end

    write(root, "scripts/check.sh", "mix docs.check\n")
    write_registry(root, registry)
    track(root)
    assert_raise ArgumentError, ~r/must exist and run in its fast chain/, fn -> AgentCodeCheck.check(root: root) end
  end

  test "zero waterline rejects stale, dated, and preference baseline release data", %{
    registry: registry,
    root: root
  } do
    attempts = [
      [%{"clause" => "G-04", "path" => "lib/gone.ex", "identifier" => "file_lines", "reason" => "stale"}],
      [%{"clause" => "G-04", "path" => "lib/large.ex", "identifier" => "file_lines", "reason" => "old", "expires_on" => "2026-12-31"}],
      [%{"clause" => "G-04", "path" => "lib/large.ex", "identifier" => "file_lines", "reason" => "human readers prefer it"}]
    ]

    Enum.each(attempts, fn baseline ->
      write_registry(root, Map.put(registry, "baseline", baseline))
      track(root)

      assert_raise ArgumentError, ~r/registry requires exactly/, fn ->
        AgentCodeCheck.check(root: root)
      end
    end)
  end

  test "reports and the single human waterline are stable", %{registry: registry, root: root} do
    write(root, "lib/z.ex", lines(4))
    write(root, "lib/a.ex", lines(4))
    write_registry(root, registry, active: [], rule_limits: %{"file_lines" => {2, 1}})
    track(root)

    first = AgentCodeCheck.check(root: root)
    second = AgentCodeCheck.check(root: root)
    output = AgentCodeCheck.human_output(first)

    assert first == second
    assert first["status"] == "pass"
    assert first["waterline"] == %{"baseline_remaining" => 0, "file_lines_headroom" => -2}
    assert length(Regex.scan(~r/^agent_code waterline:/m, output)) == 1

    assert first["findings"] ==
             Enum.sort_by(first["findings"], &{&1["threshold"], &1["target"], &1["tier"]})
  end

  defp failures(report), do: Enum.filter(report["findings"], &(&1["status"] == "failure"))

  defp lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}") <> "\n"

  defp fixture_source_line_count(content) do
    newlines = content |> :binary.matches("\n") |> length()
    if content == "" or String.ends_with?(content, "\n"), do: newlines, else: newlines + 1
  end

  defp repeated_definitions(count, offset \\ 1) do
    Enum.map_join(offset..(offset + count - 1), "\n", fn number ->
      "defmodule Sample#{number} do\n  def shared, do: :ok\nend"
    end)
  end

  defp write_registry(root, registry, opts \\ []) do
    active = MapSet.new(Keyword.get(opts, :active, ["file_lines"]))
    limits = Keyword.get(opts, :rule_limits, %{})

    thresholds =
      Enum.map(registry["thresholds"], fn threshold ->
        threshold = Map.put(threshold, "status", if(MapSet.member?(active, threshold["id"]), do: "enforced", else: "record_only"))

        case Map.get(limits, threshold["id"]) do
          {redline, default} -> threshold |> Map.put("redline", redline) |> Map.put("default", default)
          nil -> threshold
        end
      end)

    registry =
      registry
      |> Map.put("thresholds", thresholds)
      |> put_in(["gates", Access.at(0), "thresholds"], Enum.sort(active))

    write(root, "config/agent_code_governance.yml", Jason.encode!(registry))
  end

  defp write_raw_registry(root, registry) do
    write(root, "config/agent_code_governance.yml", Jason.encode!(registry))
  end

  defp track(root) do
    {_output, 0} = System.cmd("git", ["-C", root, "add", "-A"])
  end

  defp write(root, path, content) do
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, content)
  end
end
