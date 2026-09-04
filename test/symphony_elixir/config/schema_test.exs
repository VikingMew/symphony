defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "default policy uses the trimmed PR-first workflow" do
    refute Map.has_key?(Schema.default_profiles(), "merge")

    assert Schema.default_profiles()["implementation"]["allowed_updates"]["target_states"] ==
             ["In Progress", "Ready to Merge"]

    assert Schema.default_workflow_policy()["states"] == %{
             "Todo" => %{"profile" => "refinement"},
             "Refining" => %{"profile" => "refinement"},
             "Ready" => %{"profile" => "implementation"},
             "In Progress" => %{"profile" => "implementation"}
           }

    assert Schema.default_workflow_policy()["human_review_states"] == [
             "Needs Refinement Review",
             "Ready to Merge",
             "Blocked"
           ]

    assert length(Schema.default_workflow_policy()["allowed_transitions"]) == 15
  end

  test "persisted workflow policy cannot alter runtime routing" do
    persisted = %{
      "tracker" => %{
        "active_states" => ["Ready"],
        "terminal_states" => ["Canceled", "Cancelled", "Duplicate", "Done"]
      },
      "workflow" => %{
        "states" => %{"Legacy" => %{"profile" => "legacy"}},
        "human_review_states" => ["Legacy Review"],
        "allowed_transitions" => [%{"from" => "Legacy", "to" => "Legacy Review", "actor" => "robot"}]
      }
    }

    assert {:ok, settings} = Schema.parse(persisted)
    assert settings.workflow == Schema.default_workflow_policy()
    assert Schema.workflow_profile_for_state(settings, "Ready") == "implementation"
    assert Schema.workflow_profile_for_state(settings, "Legacy") == nil
    assert Schema.human_review_state?(settings, "Blocked")
    refute Schema.human_review_state?(settings, "Legacy Review")
  end
end
