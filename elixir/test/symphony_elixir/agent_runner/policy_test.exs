defmodule SymphonyElixir.AgentRunner.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRunner.Policy
  alias SymphonyElixir.Linear.Issue

  test "detects implementation start transition only for Ready implementation issues" do
    assert Policy.implementation_start_transition_required?(%Issue{state: "Ready"}, "implementation")
    refute Policy.implementation_start_transition_required?(%Issue{state: "In Progress"}, "implementation")
    refute Policy.implementation_start_transition_required?(%Issue{state: "Ready"}, "refinement")
  end

  test "matches allowed workflow transitions by state profile and actor" do
    transitions = [
      %{"from" => "Ready", "to" => "In Progress", "profile" => "implementation", "actor" => "codex"},
      %{"from" => "Ready", "to" => "Done", "actor" => "human"}
    ]

    assert Policy.workflow_transition_allowed?(transitions, "ready", "in progress", "implementation")
    refute Policy.workflow_transition_allowed?(transitions, "Ready", "Done", "implementation")
  end

  test "continues only while refreshed issue remains active" do
    issue = %Issue{id: "issue-1", state: "Ready"}
    fetch_active = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "In Progress"}]} end
    fetch_done = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "Done"}]} end

    assert {:continue, %Issue{state: "In Progress"}} = Policy.continue_with_issue?(issue, fetch_active, ["Ready", "In Progress"])
    assert {:done, %Issue{state: "Done"}} = Policy.continue_with_issue?(issue, fetch_done, ["Ready", "In Progress"])
  end

  test "selects worker host deterministically" do
    assert Policy.selected_worker_host(nil, [" worker-a ", "worker-a", "worker-b"]) == "worker-a"
    assert Policy.selected_worker_host("preferred", ["worker-a"]) == "preferred"
    assert Policy.selected_worker_host(nil, []) == nil
  end

  test "summarizes hook timeout output compactly" do
    summary =
      Policy.failure_summary({:workspace_hook_timeout, "project_bootstrap", 60_000, %{elapsed_ms: 60_001, recent_output: "one\rtwo\nthree"}})

    assert summary =~ "workspace_hook_timeout hook=project_bootstrap"
    assert summary =~ "elapsed_ms=60001"
    assert summary =~ "one | two | three"
  end
end
