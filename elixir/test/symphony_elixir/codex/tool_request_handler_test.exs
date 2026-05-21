defmodule SymphonyElixir.Codex.ToolRequestHandlerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ToolRequestHandler

  describe "approval requests" do
    test "auto-approves command approval requests when policy allows it" do
      payload = %{"id" => 99, "params" => %{"command" => "gh pr view"}}

      assert ToolRequestHandler.handle("item/commandExecution/requestApproval", payload,
               auto_approve_requests: true,
               tool_executor: unused_tool_executor()
             ) ==
               {:reply, %{"id" => 99, "result" => %{"decision" => "acceptForSession"}}, :approval_auto_approved, %{decision: "acceptForSession"}}
    end

    test "requires approval when auto approval is disabled" do
      payload = %{"id" => 99, "params" => %{"command" => "gh pr view"}}

      assert ToolRequestHandler.handle("item/commandExecution/requestApproval", payload,
               auto_approve_requests: false,
               tool_executor: unused_tool_executor()
             ) == :approval_required
    end
  end

  describe "dynamic tool calls" do
    test "returns a reply action with normalized successful tool results" do
      payload = %{
        "id" => 7,
        "params" => %{
          "tool" => "linear_task_read",
          "arguments" => %{"issue_identifier" => "ABC-1"}
        }
      }

      executor = fn "linear_task_read", %{"issue_identifier" => "ABC-1"} ->
        %{"success" => true, "contentItems" => [%{"text" => "task body"}]}
      end

      assert {:reply, reply, :tool_call_completed, %{}} =
               ToolRequestHandler.handle("item/tool/call", payload,
                 auto_approve_requests: false,
                 tool_executor: executor
               )

      assert reply["id"] == 7
      assert get_in(reply, ["result", "output"]) == "task body"
      assert get_in(reply, ["result", "contentItems"]) == [%{"text" => "task body"}]
    end

    test "marks missing tool names as unsupported tool calls" do
      payload = %{"id" => 8, "params" => %{"arguments" => %{}}}

      assert {:reply, reply, :unsupported_tool_call, %{}} =
               ToolRequestHandler.handle("item/tool/call", payload,
                 auto_approve_requests: false,
                 tool_executor: fn nil, %{} -> %{"success" => false, "output" => "unsupported"} end
               )

      assert get_in(reply, ["result", "success"]) == false
    end
  end

  describe "request user input" do
    test "answers approval-style user input prompts when auto approval is enabled" do
      payload = %{
        "id" => 110,
        "params" => %{
          "questions" => [
            %{
              "id" => "approve-call-1",
              "options" => [%{"label" => "Deny"}, %{"label" => "Approve this Session"}]
            }
          ]
        }
      }

      assert {:reply, reply, :approval_auto_approved, %{decision: "Approve this Session"}} =
               ToolRequestHandler.handle("item/tool/requestUserInput", payload,
                 auto_approve_requests: true,
                 tool_executor: unused_tool_executor()
               )

      assert get_in(reply, ["result", "answers", "approve-call-1", "answers"]) == ["Approve this Session"]
    end

    test "falls back to the non-interactive unavailable answer" do
      payload = %{"id" => 111, "params" => %{"questions" => [%{"id" => "question-1"}]}}

      assert {:reply, reply, :tool_input_auto_answered, %{answer: answer}} =
               ToolRequestHandler.handle("item/tool/requestUserInput", payload,
                 auto_approve_requests: false,
                 tool_executor: unused_tool_executor()
               )

      assert answer == "This is a non-interactive session. Operator input is unavailable."
      assert get_in(reply, ["result", "answers", "question-1", "answers"]) == [answer]
    end

    test "stops when a user input request cannot be answered" do
      payload = %{"id" => 112, "params" => %{"questions" => [%{"header" => "missing id"}]}}

      assert ToolRequestHandler.handle("item/tool/requestUserInput", payload,
               auto_approve_requests: false,
               tool_executor: unused_tool_executor()
             ) == :input_required
    end
  end

  describe "input-required detection" do
    test "detects MCP elicitation and turn input-required payloads" do
      assert ToolRequestHandler.needs_input?("mcpServer/elicitation/request", %{})
      assert ToolRequestHandler.needs_input?("turn/event", %{"params" => %{"requiresInput" => true}})
      refute ToolRequestHandler.needs_input?("turn/event", %{"params" => %{}})
    end
  end

  defp unused_tool_executor do
    fn _tool, _arguments -> flunk("tool executor should not be called") end
  end
end
