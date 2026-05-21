defmodule SymphonyElixir.Config.WorkflowContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.WorkflowContract

  test "validates state profile references and transition state references" do
    workflow = %{
      "states" => %{"Ready" => %{"profile" => "missing_profile"}},
      "human_review_states" => [],
      "allowed_transitions" => [%{"from" => "Ready", "to" => "Unknown", "actor" => "codex"}]
    }

    errors = WorkflowContract.workflow_errors(workflow, %{}, tracker())

    assert "states.Ready.profile references unknown profile missing_profile" in errors
    assert "allowed_transitions.to references unknown workflow state \"Unknown\"" in errors
  end

  test "validates profile prompt and allowed target state contract" do
    profiles = %{
      "implementation" => %{
        "name" => "Implementation",
        "executor" => %{"type" => "codex_agent"},
        "prompt" => %{"mode" => "extend"},
        "allowed_updates" => %{"target_states" => ["Ready"]}
      }
    }

    assert "profiles.implementation.prompt.template must be a non-empty string for codex_agent extend mode" in WorkflowContract.profile_errors(profiles)
  end

  test "enforces Linear state name length across workflow and tracker state names" do
    long_state = "Needs Implementation Review"
    workflow = %{"states" => %{long_state => %{"profile" => "implementation"}}}
    tracker = tracker(active_states: [long_state])

    errors = WorkflowContract.workflow_errors(workflow, %{}, tracker)

    assert Enum.any?(errors, &String.contains?(&1, "states.#{long_state} exceeds Linear state name limit"))
    assert Enum.any?(errors, &String.contains?(&1, "tracker.active_states exceeds Linear state name limit"))
  end

  test "normalizes atom-keyed input without dynamic atom conversion" do
    workflow = %{
      states: %{Ready: %{profile: "implementation"}},
      human_review_states: ["In Review"],
      allowed_transitions: [%{from: "Ready", to: "In Review", actor: "codex", profile: "implementation"}]
    }

    assert WorkflowContract.workflow_errors(workflow, %{}, tracker()) == []
  end

  test "computes known workflow states from workflow and tracker settings" do
    states =
      %{states: %{Ready: %{profile: "implementation"}}, human_review_states: ["In Review"]}
      |> WorkflowContract.known_states(tracker(terminal_states: ["Done"]))

    assert MapSet.member?(states, Schema.normalize_issue_state("Ready"))
    assert MapSet.member?(states, Schema.normalize_issue_state("In Review"))
    assert MapSet.member?(states, Schema.normalize_issue_state("Done"))
  end

  defp tracker(overrides \\ []) do
    struct!(
      Schema.Tracker,
      Keyword.merge(
        [
          kind: "linear",
          endpoint: "https://api.linear.app/graphql",
          active_states: ["Ready", "In Progress"],
          terminal_states: ["Done"]
        ],
        overrides
      )
    )
  end
end
