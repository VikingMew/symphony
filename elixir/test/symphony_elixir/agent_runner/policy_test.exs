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
    assert {:done, %Issue{state: "Done"}, :inactive_state} = Policy.continue_with_issue?(issue, fetch_done, ["Ready", "In Progress"])
  end

  test "continuation requires same executable workflow profile" do
    issue = %Issue{id: "issue-1", state: "Refining"}
    fetch = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "Refining"}]} end

    settings = %{
      active_states: ["Refining", "Ready", "In Progress"],
      terminal_states: ["Done"],
      current_profile: "refinement",
      profile_for_state: fn
        "Refining" -> "refinement"
        "Ready" -> "implementation"
        _ -> nil
      end,
      executor_for_state: fn _ -> "codex_agent" end,
      human_review_state?: fn _ -> false end
    }

    assert {:continue, %Issue{state: "Refining"}} = Policy.continue_with_issue?(issue, fetch, settings)

    fetch_review = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "Needs Refinement Review"}]} end

    assert {:done, %Issue{state: "Needs Refinement Review"}, :inactive_state} =
             Policy.continue_with_issue?(issue, fetch_review, settings)

    fetch_missing_profile = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "In Progress"}]} end

    assert {:done, %Issue{state: "In Progress"}, :missing_workflow_profile} =
             Policy.continue_with_issue?(issue, fetch_missing_profile, settings)

    fetch_profile_change = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "Ready"}]} end

    assert {:done, %Issue{state: "Ready"}, :profile_changed} =
             Policy.continue_with_issue?(issue, fetch_profile_change, settings)
  end

  test "continuation stops on human review states before another turn" do
    issue = %Issue{id: "issue-1", state: "Refining"}
    fetch = fn ["issue-1"] -> {:ok, [%Issue{id: "issue-1", state: "Needs Refinement Review"}]} end

    settings = %{
      active_states: ["Refining", "Needs Refinement Review"],
      terminal_states: ["Done"],
      current_profile: "refinement",
      profile_for_state: fn
        "Needs Refinement Review" -> "refinement"
        _ -> "refinement"
      end,
      executor_for_state: fn _ -> "codex_agent" end,
      human_review_state?: fn state -> state == "Needs Refinement Review" end
    }

    assert {:done, %Issue{state: "Needs Refinement Review"}, :human_review_state} =
             Policy.continue_with_issue?(issue, fetch, settings)
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
