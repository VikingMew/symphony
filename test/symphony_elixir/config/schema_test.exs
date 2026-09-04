defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "description limits use defaults and reject non-positive or non-integer values" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.profiles["refinement"]["description_limits"]["characters"] == 12_000
    assert settings.profiles["refinement"]["description_limits"]["lines"] == 400

    for invalid <- [0, -1, "12"] do
      config = %{
        "profiles" => %{
          "refinement" => %{"description_limits" => %{"characters" => invalid}}
        }
      }

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
      assert message =~ "profiles.refinement.description_limits.characters must be a positive integer"
    end
  end

  test "description label overrides require positive integer limits" do
    config = %{
      "profiles" => %{
        "refinement" => %{
          "description_limits" => %{
            "label_overrides" => %{"complex" => %{"lines" => 0}}
          }
        }
      }
    }

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    assert message =~ "profiles.refinement.description_limits.label_overrides.complex.lines"
  end

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

    assert length(Schema.default_workflow_policy()["allowed_transitions"]) == 16
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
