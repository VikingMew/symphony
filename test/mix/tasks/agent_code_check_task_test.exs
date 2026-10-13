defmodule Mix.Tasks.AgentCode.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AgentCode.Check

  setup do
    Mix.Task.reenable("agent_code.check")
    :ok
  end

  test "default output is concise and JSON output is a single parseable object" do
    human = capture_io(fn -> assert nil == Check.run([]) end)
    assert human =~ "agent_code.check: PASS (6 thresholds, 1 active"
    assert length(Regex.scan(~r/^agent_code waterline:/m, human)) == 1

    Mix.Task.reenable("agent_code.check")
    json = capture_io(fn -> assert nil == Check.run(["--format", "json"]) end)
    report = Jason.decode!(json)

    assert report["schema"] == "agent-facing-code-report"
    assert report["status"] == "pass"
    assert report["summary"]["thresholds"] == 6
    assert report["governance"]["clauses"] == 8
    assert report["waterline"]["baseline_remaining"] == 0
    refute Enum.any?(report["findings"], &(&1["threshold"] == "resident_rule_lines" or &1["target"] == "AGENTS.md"))
  end

  test "list and stats expose the same closed-set source facts in human and JSON formats" do
    list = capture_io(fn -> assert :ok == Check.run(["list"]) end) |> String.split("\n", trim: true)
    assert list == Enum.sort(list)

    Mix.Task.reenable("agent_code.check")
    stats_human = capture_io(fn -> assert :ok == Check.run(["stats"]) end)
    assert stats_human =~ "agent_code sources: tracked="

    Mix.Task.reenable("agent_code.check")
    stats_json = capture_io(fn -> assert :ok == Check.run(["stats", "--format", "json"]) end) |> Jason.decode!()
    summary = stats_json["summary"]

    assert summary["tracked"] == summary["handwritten"] + summary["excluded"]
    assert summary["handwritten"] == length(list)
  end

  test "invalid options fail with the stable usage" do
    assert_raise Mix.Error, ~r/Usage: mix agent_code.check/, fn -> Check.run(["--format", "xml"]) end
  end

  test "checked-in CI invokes the three gates and the fast gate owns agent conformance" do
    workflow = File.read!(".github/workflows/make-all.yml")
    check = File.read!("scripts/check.sh")
    quality = File.read!("scripts/quality.sh")

    assert workflow =~ "run: scripts/quality.sh"
    assert check =~ "mix agent_code.check"
    assert quality =~ "elixir scripts/quality.exs"
    assert File.read!("scripts/quality.exs") =~ "~w(check unit dialyzer)"
  end

  test "the checked-in registry contains G-01 through G-08 and the six thresholds" do
    registry = YamlElixir.read_from_file!("config/agent_code_governance.yml")

    assert Enum.map(registry["clauses"], & &1["id"]) ==
             ~w(G-01 G-02 G-03 G-04 G-05 G-06 G-07 G-08)

    assert Enum.map(registry["thresholds"], & &1["id"]) ==
             ~w(file_lines function_lines nesting_depth identifier_occurrences full_gate_minutes change_lines)

    refute File.exists?("config/agent_code_thresholds.yml")
    refute File.exists?("config/agent_code_exemptions.yml")
    refute File.read!("lib/symphony_elixir/agent_code_check.ex") =~ "resident_rule_lines"

    audit = File.read!("docs/agent-facing-code-audit.md")
    assert length(Regex.scan(~r/^\| \d{2} \|/m, audit)) == 35
  end
end
