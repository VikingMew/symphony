defmodule SymphonyElixir.Codex.MessageHumanizer.MethodsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.MessageHumanizer.Methods

  test "humanizes JSON-RPC method payloads independently" do
    payload = %{
      "params" => %{
        "turn" => %{"status" => "completed"},
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }
    }

    assert Methods.humanize("turn/completed", payload) == "turn completed (completed) (in 10, out 5)"
  end

  test "delegates codex wrapper method payloads to wrapper formatter" do
    payload = %{"params" => %{"msg" => %{"command" => "git status --short"}}}

    assert Methods.humanize("codex/event/exec_command_begin", payload) == "git status --short"
  end

  test "humanizes thread, turn, diff, plan, and token lifecycle messages" do
    assert Methods.humanize("thread/started", %{"params" => %{"thread" => %{"id" => "thread-1"}}}) == "thread started (thread-1)"
    assert Methods.humanize("thread/started", %{}) == "thread started"
    assert Methods.humanize("turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}) == "turn started (turn-1)"
    assert Methods.humanize("turn/started", %{}) == "turn started"
    assert Methods.humanize("turn/failed", %{"params" => %{"error" => %{"message" => "boom"}}}) == "turn failed: boom"
    assert Methods.humanize("turn/failed", %{}) == "turn failed"
    assert Methods.humanize("turn/cancelled", %{}) == "turn cancelled"
    assert Methods.humanize("turn/diff/updated", %{"params" => %{"diff" => "a\nb\n"}}) == "turn diff updated (2 lines)"
    assert Methods.humanize("turn/diff/updated", %{}) == "turn diff updated"
    assert Methods.humanize("turn/plan/updated", %{"params" => %{"steps" => [%{}, %{}]}}) == "plan updated (2 steps)"
    assert Methods.humanize("turn/plan/updated", %{"params" => %{"plan" => "bad"}}) == "plan updated"

    assert Methods.humanize("thread/tokenUsage/updated", %{"params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => 1, "output_tokens" => 2}}}}) ==
             "thread token usage updated (in 1, out 2)"

    assert Methods.humanize("thread/tokenUsage/updated", %{}) == "thread token usage updated"
  end

  test "humanizes item lifecycle and streaming methods" do
    item = %{"params" => %{"item" => %{"type" => "commandExecution", "status" => "in_progress", "id" => "abcdefghijklmnop"}}}
    assert Methods.humanize("item/started", item) == "item started: command execution (abcdefghijkl, in progress)"
    assert Methods.humanize("item/completed", %{"params" => %{"item" => %{"type" => "tool_call"}}}) == "item completed: tool call"

    assert Methods.humanize("item/agentMessage/delta", %{"params" => %{"textDelta" => "hello\nworld"}}) == "agent message streaming: hello world"
    assert Methods.humanize("item/plan/delta", %{}) == "plan streaming"
    assert Methods.humanize("item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "summary"}}) == "reasoning summary streaming: summary"
    assert Methods.humanize("item/reasoning/summaryPartAdded", %{"params" => %{"text" => "part"}}) == "reasoning summary section added: part"
    assert Methods.humanize("item/reasoning/textDelta", %{"params" => %{"msg" => %{"payload" => %{"text" => "reason"}}}}) == "reasoning text streaming: reason"
    assert Methods.humanize("item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "out"}}) == "command output streaming: out"
    assert Methods.humanize("item/fileChange/outputDelta", %{"params" => %{"msg" => %{"content" => "diff"}}}) == "file change output streaming: diff"
  end

  test "humanizes approval, account, and fallback methods" do
    assert Methods.humanize("item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => %{"cmd" => "git", "args" => ["push"]}}}) ==
             "command approval requested (git push)"

    assert Methods.humanize("item/commandExecution/requestApproval", %{}) == "command approval requested"
    assert Methods.humanize("item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 3}}) == "file change approval requested (3 files)"
    assert Methods.humanize("item/fileChange/requestApproval", %{}) == "file change approval requested"
    assert Methods.humanize("item/tool/requestUserInput", %{"params" => %{"question" => "Pick one\nnow"}}) == "tool requires user input: Pick one now"
    assert Methods.humanize("tool/requestUserInput", %{}) == "tool requires user input"
    assert Methods.humanize("account/updated", %{"params" => %{"authMode" => "api-key"}}) == "account updated (auth api-key)"

    assert Methods.humanize("account/rateLimits/updated", %{"params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 42, "windowDurationMins" => 300}}}}) ==
             "rate limits updated: primary 42% / 300m"

    assert Methods.humanize("account/chatgptAuthTokens/refresh", %{}) == "account auth token refresh requested"
    assert Methods.humanize("unknown/method", %{"params" => %{"msg" => %{"type" => "custom"}}}) == "unknown/method (custom)"
    assert Methods.humanize("unknown/method", %{}) == "unknown/method"
  end
end
