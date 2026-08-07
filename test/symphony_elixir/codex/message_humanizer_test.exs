defmodule SymphonyElixir.Codex.MessageHumanizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer

  test "humanizes nil and plain strings" do
    assert MessageHumanizer.humanize_codex_message(nil) == "no codex message yet"
    assert MessageHumanizer.humanize_codex_message("already readable") == "already readable"
  end

  test "humanizes rate limit payloads" do
    message = %{
      "method" => "account/rateLimits/updated",
      "params" => %{
        "rateLimits" => %{
          "primary" => %{"usedPercent" => 42, "windowDurationMins" => 300}
        }
      }
    }

    assert MessageHumanizer.humanize_codex_message(message) == "rate limits updated: primary 42% / 300m"
  end

  test "humanizes structured command and dynamic tool messages" do
    command = %{
      "method" => "codex/event/exec_command_begin",
      "params" => %{"msg" => %{"command" => "git status --short"}}
    }

    tool = %{
      event: :tool_call_completed,
      message: %{"payload" => %{"params" => %{"tool" => "linear_task_update"}}}
    }

    assert MessageHumanizer.humanize_codex_message(command) == "git status --short"
    assert MessageHumanizer.humanize_codex_message(tool) == "dynamic tool call completed (linear_task_update)"
  end

  test "humanizes reasoning and streaming messages" do
    reasoning = %{
      "method" => "codex/event/agent_reasoning",
      "params" => %{"msg" => %{"payload" => %{"summaryText" => "Checking the run result"}}}
    }

    delta = %{
      "method" => "item/agentMessage/delta",
      "params" => %{"delta" => "final answer"}
    }

    assert MessageHumanizer.humanize_codex_message(reasoning) == "reasoning update: Checking the run result"
    assert MessageHumanizer.humanize_codex_message(delta) == "agent message streaming: final answer"
  end
end
