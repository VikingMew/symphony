defmodule SymphonyElixir.Config.WorkflowContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Tracker
  alias SymphonyElixir.Config.WorkflowContract

  test "Blocked is non-dispatchable and uses symphony and human actors" do
    workflow = Schema.default_workflow_policy()

    tracker = %Tracker{
      active_states: ["Refining", "Ready", "In Progress"]
    }

    assert WorkflowContract.workflow_errors(workflow, %{}, tracker) == []

    invalid = put_in(workflow, ["states", "Blocked"], %{"profile" => "implementation"})

    assert Enum.any?(
             WorkflowContract.workflow_errors(invalid, %{}, tracker),
             &String.contains?(&1, "must not dispatch")
           )

    invalid_actor =
      update_in(workflow["allowed_transitions"], fn transitions ->
        Enum.map(transitions, fn
          %{"from" => "In Progress", "to" => "Blocked"} = transition ->
            Map.put(transition, "actor", "codex")

          transition ->
            transition
        end)
      end)

    errors = WorkflowContract.workflow_errors(invalid_actor, %{}, tracker)
    assert Enum.any?(errors, &String.contains?(&1, "actor=symphony"))

    assert Enum.any?(workflow["allowed_transitions"], fn transition ->
             transition == %{
               "from" => "Ready to Merge",
               "to" => "Blocked",
               "actor" => "symphony"
             }
           end)
  end

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

    assert Enum.any?(
             errors,
             &String.contains?(&1, "states.#{long_state} exceeds Linear state name limit")
           )

    assert Enum.any?(
             errors,
             &String.contains?(&1, "tracker.active_states exceeds Linear state name limit")
           )
  end

  test "normalizes atom-keyed input without dynamic atom conversion" do
    workflow = %{
      states: %{Ready: %{profile: "implementation"}},
      human_review_states: ["Ready to Merge"],
      allowed_transitions: [
        %{from: "Ready", to: "Ready to Merge", actor: "codex", profile: "implementation"}
      ]
    }

    assert WorkflowContract.workflow_errors(workflow, %{}, tracker()) == []
  end

  test "computes known workflow states from workflow and tracker settings" do
    states =
      %{states: %{Ready: %{profile: "implementation"}}, human_review_states: ["Ready to Merge"]}
      |> WorkflowContract.known_states(tracker(terminal_states: ["Done"]))

    assert MapSet.member?(states, Schema.normalize_issue_state("Ready"))
    assert MapSet.member?(states, Schema.normalize_issue_state("Ready to Merge"))
    assert MapSet.member?(states, Schema.normalize_issue_state("Done"))
  end

  test "rejects the retired implementation review lifecycle" do
    workflow = %{
      "states" => %{
        "In Progress" => %{"profile" => "implementation"},
        "Ready to Merge" => %{"profile" => "implementation"}
      },
      "human_review_states" => ["Needs Refinement Review", "In Review"],
      "allowed_transitions" => [
        %{
          "from" => "In Progress",
          "to" => "In Review",
          "actor" => "codex",
          "profile" => "implementation"
        },
        %{"from" => "In Review", "to" => "In Progress", "actor" => "human"}
      ]
    }

    profiles = %{
      "implementation" => %{
        "allowed_updates" => %{"target_states" => ["In Review"]}
      }
    }

    errors = WorkflowContract.workflow_errors(workflow, profiles, tracker())

    assert "workflow.human_review_states must include \"Ready to Merge\"" in errors
    assert "workflow.human_review_states must not include retired state \"In Review\"" in errors
    assert "workflow.states must not dispatch human-review state \"Ready to Merge\"" in errors

    assert "profiles.implementation.allowed_updates.target_states must include \"In Progress\"" in errors

    assert "profiles.implementation.allowed_updates.target_states must include \"Ready to Merge\"" in errors

    assert "profiles.implementation.allowed_updates.target_states must not include retired state \"In Review\"" in errors

    assert "workflow.allowed_transitions must include In Progress -> Ready to Merge actor=codex profile=implementation" in errors

    assert "workflow.allowed_transitions must include Ready to Merge -> In Progress actor=human" in errors
  end

  test "accepts the PR-first implementation lifecycle" do
    workflow = %{
      "states" => %{"In Progress" => %{"profile" => "implementation"}},
      "human_review_states" => ["Needs Refinement Review", "Ready to Merge"],
      "allowed_transitions" => [
        %{
          "from" => "In Progress",
          "to" => "Ready to Merge",
          "actor" => "codex",
          "profile" => "implementation"
        },
        %{"from" => "Ready to Merge", "to" => "In Progress", "actor" => "human"}
      ]
    }

    profiles = %{
      "implementation" => %{
        "allowed_updates" => %{"target_states" => ["In Progress", "Ready to Merge"]}
      }
    }

    assert WorkflowContract.workflow_errors(workflow, profiles, tracker()) == []
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
