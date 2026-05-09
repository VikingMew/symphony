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
        "Ready to Merge",
        "Done",
        "Canceled",
        "Cancelled",
        "Duplicate"
      ])

    assert result.status == :error
    assert "Merging" in result.missing.active_states
    assert "Needs Refinement Review" in result.missing.human_review_states
    assert %{profile: "refinement", states: ["Needs Refinement Review"]} in result.missing.profile_target_states
    assert Enum.any?(result.missing.transitions, &("Needs Refinement Review" in &1.missing))
  end

  defp settings do
    %{
      tracker: %{
        active_states: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"],
        terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
      },
      workflow: %{
        "states" => %{
          "Refining" => %{"profile" => "refinement"},
          "Ready" => %{"profile" => "implementation"},
          "In Progress" => %{"profile" => "implementation"},
          "Ready to Merge" => %{"profile" => "merge"},
          "Merging" => %{"profile" => "merge"}
        },
        "human_review_states" => ["Needs Refinement Review", "Needs Implementation Review"],
        "allowed_transitions" => [
          %{"from" => "Refining", "to" => "Needs Refinement Review", "actor" => "codex", "profile" => "refinement"},
          %{"from" => "Needs Refinement Review", "to" => "Ready", "actor" => "human"},
          %{"from" => "In Progress", "to" => "Needs Implementation Review", "actor" => "codex", "profile" => "implementation"},
          %{"from" => "Ready to Merge", "to" => "Merging", "actor" => "codex", "profile" => "merge"},
          %{"from" => "Merging", "to" => "Done", "actor" => "codex", "profile" => "merge"}
        ]
      },
      profiles: %{
        "refinement" => %{"allowed_updates" => %{"target_states" => ["Needs Refinement Review"]}},
        "implementation" => %{"allowed_updates" => %{"target_states" => ["In Progress", "Needs Implementation Review"]}},
        "merge" => %{"allowed_updates" => %{"target_states" => ["Merging", "Done"]}}
      }
    }
  end
end
