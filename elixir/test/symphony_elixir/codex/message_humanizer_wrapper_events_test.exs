defmodule SymphonyElixir.Codex.MessageHumanizer.WrapperEventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer.WrapperEvents

  test "humanizes wrapper command events independently" do
    payload = %{"params" => %{"msg" => %{"exit_code" => 0}}}

    assert WrapperEvents.humanize("exec_command_end", payload) == "command completed (exit 0)"
    assert WrapperEvents.humanize("exec_command_end", %{}) == "command completed"
    assert WrapperEvents.humanize("exec_command_begin", %{"params" => %{"msg" => %{"command" => ["git", "status", "--short"]}}}) == "git status --short"
    assert WrapperEvents.humanize("exec_command_begin", %{"params" => %{"msg" => %{"parsed_cmd" => %{"cmd" => "mix", "args" => ["test"]}}}}) == "mix test"
    assert WrapperEvents.humanize("exec_command_begin", %{}) == "command started"
  end

  test "humanizes wrapper streaming events independently" do
    payload = %{"params" => %{"msg" => %{"payload" => %{"summaryText" => "Checking docs"}}}}

    assert WrapperEvents.humanize("agent_reasoning", payload) == "reasoning update: Checking docs"
    assert WrapperEvents.humanize("agent_message_delta", %{"params" => %{"msg" => %{"payload" => %{"text" => "Final\nanswer"}}}}) == "agent message streaming: Final answer"
    assert WrapperEvents.humanize("agent_message_content_delta", %{}) == "agent message content streaming"
    assert WrapperEvents.humanize("agent_reasoning_delta", %{"params" => %{"delta" => "thinking"}}) == "reasoning streaming: thinking"
    assert WrapperEvents.humanize("reasoning_content_delta", %{"params" => %{"msg" => %{"payload" => %{"delta" => "step"}}}}) == "reasoning content streaming: step"
    assert WrapperEvents.humanize("agent_reasoning", %{}) == "reasoning update"
  end

  test "humanizes wrapper lifecycle and token events" do
    assert WrapperEvents.humanize("mcp_startup_update", %{"params" => %{"msg" => %{"server" => "linear", "status" => %{"state" => "ready"}}}}) ==
             "mcp startup: linear ready"

    assert WrapperEvents.humanize("mcp_startup_complete", %{}) == "mcp startup complete"
    assert WrapperEvents.humanize("task_started", %{}) == "task started"
    assert WrapperEvents.humanize("user_message", %{}) == "user message received"
    assert WrapperEvents.humanize("agent_reasoning_section_break", %{}) == "reasoning section break"
    assert WrapperEvents.humanize("turn_diff", %{}) == "turn diff updated"
    assert WrapperEvents.humanize("exec_command_output_delta", %{}) == "command output streaming"
    assert WrapperEvents.humanize("mcp_tool_call_begin", %{}) == "mcp tool call started"
    assert WrapperEvents.humanize("mcp_tool_call_end", %{}) == "mcp tool call completed"

    token_payload = %{"params" => %{"msg" => %{"payload" => %{"type" => "token_count", "info" => %{"total_token_usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}}}}}}
    assert WrapperEvents.humanize("item_started", token_payload) == "token count update (in 2, out 3, total 5)"
    assert WrapperEvents.humanize("item_completed", %{"params" => %{"msg" => %{"payload" => %{"type" => "toolCall"}}}}) == "item completed (tool call)"
    assert WrapperEvents.humanize("unknown_event", %{"params" => %{"msg" => %{"type" => "custom"}}}) == "unknown_event (custom)"
  end
end
