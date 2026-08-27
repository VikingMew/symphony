defmodule SymphonyElixir.LinearWorkflowBootstrapTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.WorkflowBootstrap

  defmodule FakeBootstrapClient do
    @moduledoc false

    def create_workflow_state(team_id, name, opts) do
      send(self(), {:create_workflow_state, team_id, name, opts})

      case Application.get_env(:symphony_elixir, :bootstrap_fail_state) do
        ^name -> {:error, :boom}
        _ -> {:ok, %{"success" => true, "workflowState" => %{"name" => name}}}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :bootstrap_fail_state)
    on_exit(fn -> restore_env(:bootstrap_fail_state, previous) end)
    :ok
  end

  test "creates only missing states for the resolved Linear team" do
    {:ok, result} =
      WorkflowBootstrap.create_missing_statuses(
        settings(),
        ["Refining", "Ready", "Done", "Canceled", "Cancelled", "Duplicate"],
        project_data(),
        client_module: FakeBootstrapClient
      )

    assert result.created == ["In Progress", "Needs Refinement Review", "Ready to Merge"]
    assert result.failed == []
    assert_received {:create_workflow_state, "team-1", "In Progress", _opts}
    assert_received {:create_workflow_state, "team-1", "Needs Refinement Review", _opts}
    assert_received {:create_workflow_state, "team-1", "Ready to Merge", _opts}
    refute_received {:create_workflow_state, "team-1", "Ready", _opts}
  end

  test "reports partial failures" do
    Application.put_env(:symphony_elixir, :bootstrap_fail_state, "Ready to Merge")

    {:ok, result} =
      WorkflowBootstrap.create_missing_statuses(
        settings(),
        ["Refining", "Ready", "Done", "Canceled", "Cancelled", "Duplicate"],
        project_data(),
        client_module: FakeBootstrapClient
      )

    assert result.created == ["In Progress", "Needs Refinement Review"]
    assert [%{state: "Ready to Merge", reason: ":boom"}] = result.failed
  end

  defp settings do
    %{
      tracker: %{
        active_states: ["Refining", "Ready", "In Progress"],
        terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
      },
      workflow: %{
        "states" => %{"Refining" => %{}, "Ready" => %{}, "In Progress" => %{}},
        "human_review_states" => ["Needs Refinement Review", "Ready to Merge"],
        "allowed_transitions" => [
          %{"from" => "Refining", "to" => "Needs Refinement Review"},
          %{"from" => "In Progress", "to" => "Ready to Merge"}
        ]
      },
      profiles: %{
        "refinement" => %{"allowed_updates" => %{"target_states" => ["Needs Refinement Review"]}},
        "implementation" => %{"allowed_updates" => %{"target_states" => ["In Progress", "Ready to Merge"]}}
      }
    }
  end

  defp project_data do
    %{project: %{teams: [%{id: "team-1", name: "Team", states: []}]}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
