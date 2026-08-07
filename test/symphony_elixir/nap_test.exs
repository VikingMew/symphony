defmodule SymphonyElixir.NapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Nap.Results

  test "aggregates issue creation audit outcomes" do
    events = [
      audit_event(%{status: "success", result: %{"identifier" => "CCR-10"}}),
      audit_event(%{"status" => "skipped"}),
      audit_event(%{status: "failure", error: %{class: "linear_graphql_error"}}),
      audit_event(%{status: "success", result: %{"identifier" => "CCR-11"}})
    ]

    assert Results.aggregate(events) == %{
             created: 2,
             skipped: 1,
             failed: 1,
             issues: [%{"identifier" => "CCR-10"}, %{"identifier" => "CCR-11"}]
           }
  end

  test "ignores audit events that are not issue creation outcomes" do
    events = [
      audit_event(%{tool: "linear_task_update", status: "success"}),
      %{event_type: "codex.update", payload: %{tool: "linear_issue_create", status: "success"}},
      audit_event(%{status: "unknown"})
    ]

    assert Results.aggregate(events) == %{created: 0, skipped: 0, failed: 0, issues: []}
  end

  defp audit_event(payload) do
    %{
      event_type: "linear.tool_call",
      payload: Map.put_new(payload, :tool, "linear_issue_create")
    }
  end
end
