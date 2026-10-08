defmodule Mix.Tasks.AgentCodeN.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AgentCodeN.Check

  setup do
    Mix.Task.reenable("agent_code_n.check")
    :ok
  end

  test "checked-in baseline has identical one-line human and JSON waterlines" do
    human = capture_io(fn -> assert nil == Check.run([]) end)
    assert [line] = String.split(human, "\n", trim: true)
    assert [_, remaining] = Regex.run(~r/navigation baseline remaining: (\d+)$/, line)

    Mix.Task.reenable("agent_code_n.check")
    json = capture_io(fn -> assert nil == Check.run(["--format", "json"]) end)
    report = Jason.decode!(json)

    assert report["schema"] == "agent-facing-code-navigation-report"
    assert report["status"] == "pass"
    assert report["navigation_baseline_remaining"] == String.to_integer(remaining)
    assert report["findings"] == Enum.sort(report["findings"])
  end

  test "arguments fail with the stable usage" do
    assert_raise Mix.Error, ~r/Usage: mix agent_code_n.check/, fn -> Check.run(["--warn"]) end
  end

  test "mix lint owns the checker exactly once and scripts check reaches it through lint" do
    mix = File.read!("mix.exs")
    check = File.read!("scripts/check.sh")

    assert [_once] = Regex.scan(~r/agent_code_n\.check/, mix)
    assert Regex.scan(~r/agent_code_n\.check/, check) == []
    assert [_once] = Regex.scan(~r/^mix lint$/m, check)
  end

  test "the N record has nine clauses and the constitution audit remains 35 rows" do
    record = File.read!("docs/agent-facing-code-n-conformance.md")
    audit = File.read!("docs/agent-facing-code-audit.md")

    assert length(Regex.scan(~r/^\| N-0[1-9] \|/m, record)) == 9
    assert length(Regex.scan(~r/^\| \d{2} \|/m, audit)) == 35
  end
end
