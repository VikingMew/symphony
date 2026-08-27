defmodule SymphonyElixir.LinearWorkflowStateValidatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.WorkflowStateValidator

  test "reports success when Linear has every workflow state" do
    settings = settings()
    result = WorkflowStateValidator.validate(settings, WorkflowStateValidator.required_states(settings))

    assert result.status == :ok
    assert result.missing_states == []
    assert result.missing.human_review_states == []
    assert result.missing.profile_target_states == []
  end

  test "groups missing review target and active states by source" do
    result =
      WorkflowStateValidator.validate(settings(), [
        "Refining",
        "Ready",
        "In Progress",
        "Done",
        "Canceled",
        "Cancelled",
        "Duplicate"
      ])

    assert result.status == :error
    assert "Needs Refinement Review" in result.missing.human_review_states
    assert "Ready to Merge" in result.missing.human_review_states
    assert %{profile: "refinement", states: ["Needs Refinement Review"]} in result.missing.profile_target_states
    assert Enum.any?(result.missing.transitions, &("Needs Refinement Review" in &1.missing))
  end

  defp settings do
    %{
      tracker: %{
        active_states: ["Refining", "Ready", "In Progress"],
        terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
      },
      workflow: %{
        "states" => %{
          "Refining" => %{"profile" => "refinement"},
          "Ready" => %{"profile" => "implementation"},
          "In Progress" => %{"profile" => "implementation"}
        },
        "human_review_states" => ["Needs Refinement Review", "Ready to Merge"],
        "allowed_transitions" => [
          %{"from" => "Refining", "to" => "Needs Refinement Review", "actor" => "codex", "profile" => "refinement"},
          %{"from" => "Needs Refinement Review", "to" => "Ready", "actor" => "human"},
          %{"from" => "In Progress", "to" => "Ready to Merge", "actor" => "codex", "profile" => "implementation"},
          %{"from" => "Ready to Merge", "to" => "In Progress", "actor" => "human"}
        ]
      },
      profiles: %{
        "refinement" => %{"allowed_updates" => %{"target_states" => ["Needs Refinement Review"]}},
        "implementation" => %{"allowed_updates" => %{"target_states" => ["In Progress", "Ready to Merge"]}}
      }
    }
  end
end
