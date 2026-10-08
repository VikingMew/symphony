defmodule Mix.Tasks.AgentCodeX.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AgentCodeX.Check

  setup do
    Mix.Task.reenable("agent_code_x.check")
    :ok
  end

  test "checked-in record passes with the hard-gate waterline" do
    output = capture_io(fn -> assert nil == Check.run([]) end)
    assert output == "agent_code_x.check: PASS clauses=5 checkers=8 failures=0 baseline_remaining=0\n"
  end

  test "arguments fail with the stable usage" do
    assert_raise Mix.Error, ~r/Usage: mix agent_code_x.check/, fn -> Check.run(["--warn"]) end
  end

  test "mix lint owns the checker and scripts check reaches it only through lint" do
    mix = File.read!("mix.exs")
    check = File.read!("scripts/check.sh")

    assert mix =~
             ~s(lint: ["agent_code_n.check", "agent_code_x.check", "specs.check", "credo --strict"])

    assert Regex.scan(~r/agent_code_x\.check/, check) == []
    assert [_once] = Regex.scan(~r/^mix lint$/m, check)
  end
end
