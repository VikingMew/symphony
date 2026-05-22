defmodule SymphonyElixir.Codex.MessageHumanizer.WrapperEventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer.WrapperEvents

  test "humanizes wrapper command events independently" do
    payload = %{"params" => %{"msg" => %{"exit_code" => 0}}}

    assert WrapperEvents.humanize("exec_command_end", payload) == "command completed (exit 0)"
  end

  test "humanizes wrapper streaming events independently" do
    payload = %{"params" => %{"msg" => %{"payload" => %{"summaryText" => "Checking docs"}}}}

    assert WrapperEvents.humanize("agent_reasoning", payload) == "reasoning update: Checking docs"
  end
end
