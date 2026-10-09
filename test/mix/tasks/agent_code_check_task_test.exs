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
    assert human =~ "agent_code.check: PASS (6 rules, 1 active"

    Mix.Task.reenable("agent_code.check")
    json = capture_io(fn -> assert nil == Check.run(["--format", "json"]) end)
    report = Jason.decode!(json)

    assert report["schema"] == "agent-facing-code-report"
    assert report["status"] == "pass"
    assert report["summary"]["rules"] == 6
    refute Enum.any?(report["findings"], &(&1["rule"] == "resident_rule_lines" or &1["target"] == "AGENTS.md"))
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

  test "the checked-in registry and audit contain the six declared rules and 35 constitution units" do
    registry = YamlElixir.read_from_file!("config/agent_code_thresholds.yml")
    assert Enum.map(registry["rules"], & &1["id"]) == ~w(file_lines function_lines nesting_depth identifier_occurrences full_gate_minutes change_lines)

    refute File.read!("config/agent_code_exemptions.yml") =~ "resident_rule_lines"
    refute File.read!("lib/symphony_elixir/agent_code_check.ex") =~ "resident_rule_lines"

    audit = File.read!("docs/agent-facing-code-audit.md")
    assert length(Regex.scan(~r/^\| \d{2} \|/m, audit)) == 35
  end
end
