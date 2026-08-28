defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "default policy uses the trimmed PR-first workflow" do
    refute Map.has_key?(Schema.default_profiles(), "merge")

    assert Schema.default_profiles()["implementation"]["allowed_updates"]["target_states"] ==
             ["In Progress", "Ready to Merge"]

    assert Schema.default_workflow_policy()["states"] == %{
             "Refining" => %{"profile" => "refinement"},
             "Ready" => %{"profile" => "implementation"},
             "In Progress" => %{"profile" => "implementation"}
           }

    assert Schema.default_workflow_policy()["human_review_states"] == [
             "Needs Refinement Review",
             "Ready to Merge",
             "Blocked"
           ]
  end
end
