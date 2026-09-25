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
    assert human =~ "agent_code.check: PASS (7 rules, 2 active"

    Mix.Task.reenable("agent_code.check")
    json = capture_io(fn -> assert nil == Check.run(["--format", "json"]) end)
    report = Jason.decode!(json)

    assert report["schema"] == "agent-facing-code-report"
    assert report["status"] == "pass"
    assert report["summary"]["rules"] == 7
  end

  test "invalid options fail with the stable usage" do
    assert_raise Mix.Error, ~r/Usage: mix agent_code.check/, fn -> Check.run(["--format", "xml"]) end
  end

  test "checked-in CI invokes the three gates and the fast gate owns agent conformance" do
    workflow = File.read!(".github/workflows/make-all.yml")
    check = File.read!("scripts/check.sh")
    quality = File.read!("scripts/quality.sh")

    assert Regex.scan(~r/run: scripts\/(check|unit|dialyzer)\.sh/, workflow, capture: :all_but_first)
           |> List.flatten() == ~w(check unit dialyzer)

    assert check =~ "mix agent_code.check"
    assert quality =~ "scripts/check.sh\nscripts/unit.sh\nscripts/dialyzer.sh"
  end

  test "the checked-in audit contains exactly the declared 36 constitution units" do
    audit = File.read!("docs/agent-facing-code-audit.md")
    assert length(Regex.scan(~r/^\| \d{2} \|/m, audit)) == 36
  end
end
