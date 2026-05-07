defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises restricted Linear task tools" do
    assert [
             %{"name" => "linear_task_read", "inputSchema" => %{"type" => "object", "properties" => read_props}},
             %{"name" => "linear_task_update", "inputSchema" => %{"type" => "object", "properties" => update_props}}
           ] = DynamicTool.tool_specs()

    assert Map.has_key?(read_props, "include_activity")
    assert Map.has_key?(read_props, "activity_limit")
    assert Map.has_key?(update_props, "comment")
    assert Map.has_key?(update_props, "target_state")
    refute Enum.any?(DynamicTool.tool_specs(), &(&1["name"] == "linear_graphql"))
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_task_read", "linear_task_update"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_task_read normalizes defaults and returns reader output" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_read",
        %{},
        task_reader: fn payload ->
          send(test_pid, {:task_reader_called, payload})
          {:ok, %{"issue" => %{"id" => "issue-1"}}}
        end
      )

    assert_received {:task_reader_called, %{"include_activity" => true, "activity_limit" => 50, "since" => nil}}
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"issue" => %{"id" => "issue-1"}}
  end

  test "linear_task_read validates activity arguments" do
    response =
      DynamicTool.execute("linear_task_read", %{"include_activity" => "yes"}, task_reader: fn _payload -> flunk("reader should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "include_activity"

    response =
      DynamicTool.execute("linear_task_read", %{"activity_limit" => 101}, task_reader: fn _payload -> flunk("reader should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "activity_limit"
  end

  test "linear_task_update normalizes update payload and returns updater output" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_update",
        %{
          "comment" => "Ready for review",
          "target_state" => "Needs Implementation Review",
          "result" => %{"tests" => "green"}
        },
        task_updater: fn payload ->
          send(test_pid, {:task_updater_called, payload})
          {:ok, %{"ok" => true}}
        end
      )

    assert_received {:task_updater_called,
                     %{
                       "comment" => "Ready for review",
                       "target_state" => "Needs Implementation Review",
                       "result" => %{"tests" => "green"}
                     }}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"ok" => true}
  end

  test "linear_task_update rejects empty and invalid update payloads" do
    response =
      DynamicTool.execute("linear_task_update", %{}, task_updater: fn _payload -> flunk("updater should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "requires at least one"

    response =
      DynamicTool.execute("linear_task_update", %{"references" => ["bad"]}, task_updater: fn _payload -> flunk("updater should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "references"
  end

  test "linear_task_update reports unavailable default task context" do
    response = DynamicTool.execute("linear_task_update", %{"comment" => "hello"})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{"message" => "Linear task context is unavailable for this Codex session."}
           }
  end
end
