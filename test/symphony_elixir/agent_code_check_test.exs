defmodule SymphonyElixir.AgentCodeCheckTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentCodeCheck

  setup do
    original = File.cwd!()
    root = Path.join(original, "_build/agent-code-check-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "file and resident-rule redlines pass at the boundary and fail strictly above it", %{root: root} do
    write(root, "lib/boundary.ex", lines(5))
    write(root, "AGENTS.md", lines(5))
    write_registry(root, active: ~w(file_lines resident_rule_lines), redline: 5, default: 3)
    write_exemptions(root, [])

    boundary = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])
    assert boundary["status"] == "pass"
    assert AgentCodeCheck.exit_code(boundary) == 0
    assert Enum.all?(boundary["findings"], &(&1["status"] != "failure"))

    write(root, "lib/boundary.ex", lines(6))
    write(root, "AGENTS.md", lines(6))
    exceeded = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])

    assert Enum.map(failures(exceeded), &{&1["rule"], &1["value"], &1["limit"]}) == [
             {"file_lines", 6, 5},
             {"resident_rule_lines", 6, 5}
           ]

    assert AgentCodeCheck.exit_code(exceeded) == 1
  end

  test "function and nesting measurements use AST boundaries", %{root: root} do
    write(root, "AGENTS.md", "rule\n")

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

    write_registry(root,
      active: ~w(function_lines nesting_depth),
      rule_limits: %{"function_lines" => {5, 2}, "nesting_depth" => {1, 0}}
    )

    write_exemptions(root, [])
    report = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])

    assert [%{"rule" => "function_lines", "value" => 7}, %{"rule" => "nesting_depth", "value" => 2}] =
             failures(report)
  end

  test "identifier occurrence redline passes at five and fails at six", %{root: root} do
    write(root, "AGENTS.md", "rule\n")
    write(root, "lib/five.ex", repeated_definitions(5))
    write_registry(root, active: ["identifier_occurrences"], rule_limits: %{"identifier_occurrences" => {5, 1}})
    write_exemptions(root, [])

    at_limit = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])
    assert at_limit["status"] == "pass"

    write(root, "lib/six.ex", repeated_definitions(1, 6))
    exceeded = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])
    assert [%{"rule" => "identifier_occurrences", "target" => "shared", "value" => 6}] = failures(exceeded)
  end

  test "configured paths and explicit exclusions define the entire scope", %{root: root} do
    write(root, "AGENTS.md", "rule\n")
    write(root, "lib/included.ex", lines(4))
    write(root, "lib/generated/excluded.ex", lines(8))

    write_registry(root,
      active: ["file_lines"],
      redline: 3,
      exclusions: [%{"path" => "lib/generated/**", "reason" => "fixture output"}]
    )

    write_exemptions(root, [])
    report = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])

    assert [%{"target" => "lib/included.ex"}] = failures(report)
    assert Enum.all?(report["findings"], &(&1["target"] != "lib/generated/excluded.ex"))
  end

  test "an exact unexpired exemption passes and expires on the following day", %{root: root} do
    write(root, "AGENTS.md", "rule\n")
    write(root, "lib/large.ex", lines(6))
    write_registry(root, active: ["file_lines"], redline: 5)

    write_exemptions(root, [
      %{
        "rule" => "file_lines",
        "target" => "lib/large.ex",
        "owner" => "test owner",
        "reason" => "fixture migration",
        "expires_on" => "2026-09-24"
      }
    ])

    valid = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])

    assert [%{"status" => "exempted", "expires_on" => "2026-09-24"}] =
             Enum.filter(valid["findings"], &(&1["status"] == "exempted"))

    assert valid["status"] == "pass"

    expired = AgentCodeCheck.check(root: root, today: ~D[2026-09-25])
    assert [%{"status" => "failure", "reason" => "exemption expired on 2026-09-24"}] = failures(expired)
  end

  test "stale exemptions, parse errors, and unknown registry fields fail explicitly", %{root: root} do
    write(root, "AGENTS.md", "rule\n")
    write(root, "lib/broken.ex", "defmodule Broken do\n  def broken(\nend\n")
    write_registry(root, active: ["function_lines"])

    write_exemptions(root, [
      %{
        "rule" => "function_lines",
        "target" => "lib/gone.ex:gone/0:1",
        "owner" => "test owner",
        "reason" => "stale fixture",
        "expires_on" => "2026-12-31"
      }
    ])

    report = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])
    assert report["status"] == "fail"
    assert Enum.any?(report["errors"], &String.contains?(&1, "parse error"))
    assert Enum.any?(report["errors"], &String.contains?(&1, "exemption does not match"))

    registry = root |> Path.join("config/agent_code_thresholds.yml") |> File.read!() |> Jason.decode!()
    write(root, "config/agent_code_thresholds.yml", Jason.encode!(Map.put(registry, "unknown", true)))

    assert_raise ArgumentError, ~r/registry requires exactly/, fn -> AgentCodeCheck.check(root: root) end
  end

  test "findings are stable, sorted, and record-only rules never affect exit status", %{root: root} do
    write(root, "AGENTS.md", "rule\n")
    write(root, "lib/z.ex", lines(4))
    write(root, "lib/a.ex", lines(4))
    write_registry(root, active: [], redline: 2, default: 1)
    write_exemptions(root, [])

    first = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])
    second = AgentCodeCheck.check(root: root, today: ~D[2026-09-24])

    assert first == second
    assert first["status"] == "pass"
    assert first["findings"] == Enum.sort_by(first["findings"], &{&1["rule"], &1["target"], &1["tier"]})
    assert Enum.all?(first["findings"], &(&1["status"] == "record_only"))
  end

  defp failures(report), do: Enum.filter(report["findings"], &(&1["status"] == "failure"))

  defp lines(count), do: Enum.map_join(1..count, "\n", &"line #{&1}") <> "\n"

  defp repeated_definitions(count, offset \\ 1) do
    Enum.map_join(offset..(offset + count - 1), "\n", fn number ->
      "defmodule Sample#{number} do\n  def shared, do: :ok\nend"
    end)
  end

  defp write_registry(root, opts) do
    active = MapSet.new(Keyword.get(opts, :active, []))
    common_redline = Keyword.get(opts, :redline, 100)
    common_default = Keyword.get(opts, :default, 50)
    limits = Keyword.get(opts, :rule_limits, %{})
    exclusions = Keyword.get(opts, :exclusions, [])

    rules =
      for {id, kind, paths} <- [
            {"file_lines", "file_lines", ["lib/**/*.ex"]},
            {"function_lines", "function_lines", ["lib/**/*.ex"]},
            {"nesting_depth", "nesting_depth", ["lib/**/*.ex"]},
            {"identifier_occurrences", "identifier_occurrences", ["lib/**/*.ex"]},
            {"resident_rule_lines", "resident_rule_lines", ["AGENTS.md"]},
            {"full_gate_minutes", "recorded_sample", ["scripts/quality.sh"]},
            {"change_lines", "recorded_sample", ["git diff --numstat origin/main...HEAD"]}
          ] do
        {redline, default} = Map.get(limits, id, {common_redline, common_default})

        %{
          "id" => id,
          "kind" => kind,
          "scope" => %{
            "paths" => paths,
            "language" => "fixture",
            "exclusions" => if(id == "file_lines", do: exclusions, else: [])
          },
          "unit" => "fixture units",
          "redline" => redline,
          "default" => default,
          "source_nature" => "fixture source",
          "evidence_mode" => "machine",
          "status" => if(MapSet.member?(active, id), do: "enforced", else: "record_only"),
          "default_exceedance_reason" => "fixture reason",
          "calibration" => %{
            "method" => "fixture method",
            "sample" => "fixture sample",
            "sample_value" => 0,
            "date" => "2026-09-24"
          }
        }
      end

    write(
      root,
      "config/agent_code_thresholds.yml",
      Jason.encode!(%{
        "schema" => "agent-facing-code-thresholds",
        "owner" => "docs/agent-facing-code-design.md",
        "rules" => rules
      })
    )
  end

  defp write_exemptions(root, exemptions) do
    write(
      root,
      "config/agent_code_exemptions.yml",
      Jason.encode!(%{
        "schema" => "agent-facing-code-exemptions",
        "owner" => "docs/agent-facing-code-design.md",
        "exemptions" => exemptions
      })
    )
  end

  defp write(root, path, content) do
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, content)
  end
end
